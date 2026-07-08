package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"path/filepath"
	"strings"
	"time"

	"github.com/cosmos/cosmos-sdk/client"
	"github.com/cosmos/cosmos-sdk/client/flags"

	"github.com/terpnetwork/terp-core/v5/cmd/ipfs"

	"github.com/manifoldco/promptui"
	"github.com/spf13/cobra"

	"os"
	"reflect" // #nosec

	"strconv"

	govv1 "cosmossdk.io/api/cosmos/gov/v1"
	upgradetypes "cosmossdk.io/x/upgrade/types"
	"github.com/cosmos/cosmos-sdk/codec"
	sdk "github.com/cosmos/cosmos-sdk/types"
	authtypes "github.com/cosmos/cosmos-sdk/x/auth/types"
	govtypes "github.com/cosmos/cosmos-sdk/x/gov/types"
	mh "github.com/multiformats/go-multihash"
)

const (
	proposalText          = "text"
	proposalOther         = "other"
	draftProposalFileName = "draft_proposal.json"
	draftMetadataFileName = "draft_metadata.json"
)

// proposal defines the new Msg-based proposal.
type proposal struct {
	// Msgs defines an array of sdk.Msgs proto-JSON-encoded as Anys.
	Messages  []json.RawMessage `json:"messages,omitempty"`
	Metadata  string            `json:"metadata"`
	Deposit   string            `json:"deposit"`
	Title     string            `json:"title"`
	Summary   string            `json:"summary"`
	Expedited bool              `json:"expedited"`
}

// getGovVotingPeriod fetches the current voting period from x/gov params
func getGovVotingPeriod(clientCtx client.Context) time.Duration {
	queryClient := govv1.NewQueryClient(clientCtx)

	resp, err := queryClient.Params(context.Background(), &govv1.QueryParamsRequest{})
	if err == nil {
		return resp.Params.VotingPeriod.AsDuration()
	}

	// Fallback to v1beta1
	v1beta1Client := govv1.NewQueryClient(clientCtx)
	respBeta, err := v1beta1Client.Params(context.Background(), &govv1.QueryParamsRequest{})
	if err == nil {
		return respBeta.Params.VotingPeriod.AsDuration()
	}
	// Ultimate safe default
	fmt.Println("Warning: Could not query governance voting period. Using 7 days default.")
	return 7 * 24 * time.Hour
}

// calculateTargetUpgradeHeight mirrors your playground logic using live chain state
func calculateTargetUpgradeHeight(clientCtx client.Context, targetTime time.Time) (int64, error) {
	// Get current/latest block info
	node, err := clientCtx.GetNode()
	if err != nil {
		return 0, fmt.Errorf("failed to connect to node: %w", err)
	}

	status, err := node.Status(context.Background())
	if err != nil {
		return 0, fmt.Errorf("failed to get chain status: %w", err)
	}

	currentHeight := status.SyncInfo.LatestBlockHeight
	currentTime := status.SyncInfo.LatestBlockTime // this is the key

	if targetTime.Before(currentTime) {
		return 0, fmt.Errorf("target time must be in the future (current block time: %s)", currentTime.Format(time.RFC3339))
	}

	const defaultAvgBlockTime = 2.4 // seconds

	timeDiff := targetTime.Sub(currentTime).Seconds()
	futureBlocks := timeDiff / defaultAvgBlockTime

	// Add small safety buffer (e.g. +50 blocks)
	targetHeight := currentHeight + int64(futureBlocks) + 50

	fmt.Printf("Current block: %d at %s\n", currentHeight, currentTime.Format(time.RFC3339))
	fmt.Printf("Target time: %s\n", targetTime.Format(time.RFC3339))
	fmt.Printf("Estimated blocks ahead: %.0f\n", futureBlocks)
	fmt.Printf("→ Recommended upgrade height: %d\n", targetHeight)

	return targetHeight, nil
}

// generateCIDFromMetadata uses your CidFromReader logic
// generateCIDFromMetadata returns a proper ipfs:// CID for the metadata JSON
func generateCIDFromMetadata(metadata govtypes.ProposalMetadata) (string, error) {
	bz, err := json.Marshal(metadata)
	if err != nil {
		return "", err
	}

	// Use DagJSON codec (recommended for metadata) + sha2-256
	hash, err := mh.Sum(bz, mh.SHA2_256, -1)
	if err != nil {
		return "", err
	}

	c := ipfs.NewCidV1(ipfs.DagJSON, hash) // or cid.Raw if you prefer

	return "ipfs://" + c.String(), nil
}

func cidFromBytes(data []byte) (ipfs.Cid, error) {
	r := bytes.NewReader(data)
	_, c, err := ipfs.CidFromReader(r) // your imported function
	return c, err
}

// Prompt prompts the user for all values of the given type.
// data is the struct to be filled
// namePrefix is the name to be displayed as "Enter <namePrefix> <field>"
// TODO: when bringing this in autocli, use proto message instead
// this will simplify the get address logic
func Prompt[T any](data T, namePrefix string) (T, error) {
	v := reflect.ValueOf(&data).Elem()
	if v.Kind() == reflect.Interface {
		v = reflect.ValueOf(data)
		if v.Kind() == reflect.Ptr {
			v = v.Elem()
		}
	}

	for i := range v.NumField() {
		// if the field is a struct skip or not slice of string or int then skip
		switch v.Field(i).Kind() {
		case reflect.Struct:
			// TODO(@julienrbrt) in the future we can add a recursive call to Prompt
			continue
		case reflect.Slice:
			if v.Field(i).Type().Elem().Kind() != reflect.String && v.Field(i).Type().Elem().Kind() != reflect.Int {
				continue
			}
		}

		// create prompts
		prompt := promptui.Prompt{
			Label:    fmt.Sprintf("Enter %s %s", namePrefix, strings.ToLower(client.CamelCaseToString(v.Type().Field(i).Name))),
			Validate: client.ValidatePromptNotEmpty,
		}

		fieldName := strings.ToLower(v.Type().Field(i).Name)

		if strings.EqualFold(fieldName, "authority") {
			// pre-fill with gov address
			prompt.Default = authtypes.NewModuleAddress(govtypes.ModuleName).String()
			prompt.Validate = client.ValidatePromptAddress
		}

		result, err := prompt.Run()
		if err != nil {
			return data, fmt.Errorf("failed to prompt for %s: %w", fieldName, err)
		}

		switch v.Field(i).Kind() {
		case reflect.String:
			v.Field(i).SetString(result)
		case reflect.Int:
			resultInt, err := strconv.ParseInt(result, 10, 0)
			if err != nil {
				return data, fmt.Errorf("invalid value for int: %w", err)
			}
			// If a value was successfully parsed the ranges of:
			//      [minInt,     maxInt]
			// are within the ranges of:
			//      [minInt64, maxInt64]
			// of which on 64-bit machines, which are most common,
			// int==int64
			v.Field(i).SetInt(resultInt)
		case reflect.Slice:
			switch v.Field(i).Type().Elem().Kind() {
			case reflect.String:
				v.Field(i).Set(reflect.ValueOf([]string{result}))
			case reflect.Int:
				resultInt, err := strconv.ParseInt(result, 10, 0)
				if err != nil {
					return data, fmt.Errorf("invalid value for int: %w", err)
				}

				v.Field(i).Set(reflect.ValueOf([]int{int(resultInt)}))
			}
		default:
			// skip any other types
			continue
		}
	}

	return data, nil
}

type proposalType struct {
	Name    string
	MsgType string
	Msg     sdk.Msg
}

// Prompt the proposal type values and return the proposal and its metadata
func (p *proposalType) Prompt(cdc codec.Codec, skipMetadata bool) (*proposal, govtypes.ProposalMetadata, error) {
	metadata, err := PromptMetadata(skipMetadata)
	if err != nil {
		return nil, metadata, fmt.Errorf("failed to set proposal metadata: %w", err)
	}

	proposal := &proposal{
		Metadata: "ipfs://CID", // the metadata must be saved on IPFS, set placeholder
		Title:    metadata.Title,
		Summary:  metadata.Summary,
	}

	// set deposit
	depositPrompt := promptui.Prompt{
		Label:    "Enter proposal deposit",
		Validate: client.ValidatePromptCoins,
	}
	proposal.Deposit, err = depositPrompt.Run()
	if err != nil {
		return nil, metadata, fmt.Errorf("failed to set proposal deposit: %w", err)
	}

	if p.Msg == nil {
		return proposal, metadata, nil
	}

	// set messages field
	result, err := Prompt(p.Msg, "msg")
	if err != nil {
		return nil, metadata, fmt.Errorf("failed to set proposal message: %w", err)
	}

	message, err := cdc.MarshalInterfaceJSON(result)
	if err != nil {
		return nil, metadata, fmt.Errorf("failed to marshal proposal message: %w", err)
	}
	proposal.Messages = append(proposal.Messages, message)

	return proposal, metadata, nil
}

// PromptMetadata prompts for proposal metadata or only title and summary if skip is true
func PromptMetadata(skip bool) (govtypes.ProposalMetadata, error) {
	if !skip {
		metadata, err := Prompt(govtypes.ProposalMetadata{}, "proposal")
		if err != nil {
			return metadata, fmt.Errorf("failed to set proposal metadata: %w", err)
		}

		return metadata, nil
	}

	// prompt for title and summary
	titlePrompt := promptui.Prompt{
		Label:    "Enter proposal title",
		Validate: client.ValidatePromptNotEmpty,
	}

	title, err := titlePrompt.Run()
	if err != nil {
		return govtypes.ProposalMetadata{}, fmt.Errorf("failed to set proposal title: %w", err)
	}

	summaryPrompt := promptui.Prompt{
		Label:    "Enter proposal summary",
		Validate: client.ValidatePromptNotEmpty,
	}

	summary, err := summaryPrompt.Run()
	if err != nil {
		return govtypes.ProposalMetadata{}, fmt.Errorf("failed to set proposal summary: %w", err)
	}

	return govtypes.ProposalMetadata{Title: title, Summary: summary}, nil
}
func NewReleaseProposalCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:          "draft-proposal",
		Short:        "Generate a draft software upgrade proposal with governance-aware timing",
		SilenceUsage: true,
		RunE: func(cmd *cobra.Command, _ []string) error {
			clientCtx, err := client.GetClientTxContext(cmd)
			if err != nil {
				return err
			}

			skipMetadata, _ := cmd.Flags().GetBool("skip-metadata")

			// === 1. Get governance voting period ===
			votingPeriod := getGovVotingPeriod(clientCtx)
			fmt.Printf("votingPeriod: %v\n", votingPeriod)
			// === 2. Ask user how many EXTRA days after voting ends ===
			extraDaysPrompt := promptui.Prompt{
				Label:   "How many extra days after voting period should the upgrade occur? (recommended: 2-5)",
				Default: "3",
				Validate: func(s string) error {
					if _, err := strconv.Atoi(s); err != nil {
						return fmt.Errorf("enter a valid number")
					}
					return nil
				},
			}

			extraDaysStr, err := extraDaysPrompt.Run()
			if err != nil {
				return err
			}
			extraDays, _ := strconv.Atoi(extraDaysStr)

			// Calculate target time = now + voting period + extra days
			buffer := votingPeriod + time.Duration(extraDays)*24*time.Hour
			defaultTarget := time.Now().UTC().Add(buffer)

			// === 3. Allow user to adjust the final target time ===
			timePrompt := promptui.Prompt{
				Label:    "Target upgrade datetime (RFC3339)",
				Default:  defaultTarget.Format(time.RFC3339),
				Validate: validateRFC3339,
			}
			targetStr, err := timePrompt.Run()
			if err != nil {
				return err
			}

			targetTime, _ := time.Parse(time.RFC3339, targetStr)

			// === 4. Create upgrade message with auto height ===
			msg, err := sdk.GetMsgFromTypeURL(clientCtx.Codec, "/cosmos.upgrade.v1beta1.MsgSoftwareUpgrade")
			if err != nil {
				return err
			}
			upgradeMsg := msg.(*upgradetypes.MsgSoftwareUpgrade)

			// Upgrade name
			namePrompt := promptui.Prompt{
				Label:    "Enter upgrade name (e.g. v2.0.0)",
				Validate: client.ValidatePromptNotEmpty,
			}
			upgradeMsg.Plan.Name, _ = namePrompt.Run()

			upgradeDir := filepath.Join("networks", "upgrades", upgradeMsg.Plan.Name)
			if err := os.MkdirAll(upgradeDir, 0o755); err != nil {
				return fmt.Errorf("failed to create upgrade directory: %w", err)
			}

			height, err := calculateTargetUpgradeHeight(clientCtx, targetTime)
			if err != nil {
				return err
			}
			upgradeMsg.Plan.Height = height

			infoPrompt := promptui.Prompt{Label: "Enter upgrade info (optional)"}
			upgradeMsg.Plan.Info, _ = infoPrompt.Run()

			// === Load cosmovisor.json and set Plan.Info with S3 URL + checksum ===
			cosmovisorPath := filepath.Join(upgradeDir, "cosmovisor.json")
			data, err := os.ReadFile(cosmovisorPath)
			if err == nil {
				// Compute sha256 checksum
				hash, err := mh.Sum(data, mh.SHA2_256, -1)
				if err != nil {
					fmt.Printf("Warning: failed to compute checksum: %v\n", err)
					upgradeMsg.Plan.Info = fmt.Sprintf("https://s3.terp.network/upgrades/%s/cosmovisor.json", upgradeMsg.Plan.Name)
				} else {
					checksumHex := hash.HexString()
					shortChecksum := checksumHex[:16] // first 8 bytes (16 hex chars)
					upgradeMsg.Plan.Info = fmt.Sprintf(
						"https://s3.terp.network/upgrades/%s/cosmovisor.json?sha256sum=%s",
						upgradeMsg.Plan.Name,
						shortChecksum,
					)
					fmt.Printf("✅ Loaded cosmovisor.json and set Plan.Info with checksum\n")
					fmt.Printf("   → %s\n", upgradeMsg.Plan.Info)
				}
			} else {
				fmt.Printf("Note: %s not found (you can add it later)\n", cosmovisorPath)
				// Sensible default URL
				upgradeMsg.Plan.Info = fmt.Sprintf(
					"https://s3.terp.network/upgrades/%s/cosmovisor.json",
					upgradeMsg.Plan.Name,
				)
			}

			authPrompt := promptui.Prompt{
				Label:   "Authority",
				Default: authtypes.NewModuleAddress(govtypes.ModuleName).String(),
			}
			upgradeMsg.Authority, _ = authPrompt.Run()

			// === Metadata handling + CID ===
			metadata, err := PromptMetadata(skipMetadata)
			if err != nil {
				return err
			}

			// Write draft metadata
			metadataPath := filepath.Join(upgradeDir, draftMetadataFileName)
			if err := writeFile(metadataPath, metadata); err != nil {
				return err
			}

			// Generate deterministic CID
			cidStr, err := generateCIDFromMetadata(metadata)
			if err != nil {
				fmt.Printf("Warning: could not generate CID: %v\n", err)
				cidStr = "ipfs://<CID-HERE>"
			}

			// === Build proposal ===
			prop := &proposal{
				Title:    metadata.Title,
				Summary:  metadata.Summary,
				Metadata: cidStr,
				Deposit:  "10000000uterp", // TODO: get based on proposal type (expedieted of default )
			}

			msgJSON, err := clientCtx.Codec.MarshalInterfaceJSON(upgradeMsg)
			if err != nil {
				return fmt.Errorf("failed to marshal message: %w", err)
			}
			prop.Messages = []json.RawMessage{msgJSON}

			// WRITE TO UPGRADE FOLDER
			proposalPath := filepath.Join(upgradeDir, draftProposalFileName)
			if err := writeFile(proposalPath, prop); err != nil {
				return err
			}

			fmt.Println("✅ Draft software upgrade proposal generated successfully!")
			return nil
		},
	}

	flags.AddTxFlagsToCmd(cmd)
	cmd.Flags().Bool("skip-metadata", false, "skip metadata prompt")

	return cmd
}

func validateRFC3339(input string) error {
	_, err := time.Parse(time.RFC3339, input)
	if err != nil {
		return fmt.Errorf("invalid RFC3339 format. Example: 2026-07-15T14:30:00Z")
	}
	return nil
}

// writeFile writes the input to the file
func writeFile(fileName string, input any) error {
	raw, err := json.MarshalIndent(input, "", " ")
	if err != nil {
		return fmt.Errorf("failed to marshal proposal: %w", err)
	}

	if err := os.WriteFile(fileName, raw, 0o600); err != nil {
		return err
	}

	return nil
}
