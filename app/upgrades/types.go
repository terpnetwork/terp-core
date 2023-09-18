package upgrades

import (
	"strings"
)

func GetChainsDenomToken(chainID string) string {
	if strings.HasPrefix(chainID, "90u-") {
		return "uterpx"
	}
	return "uterp"
}
