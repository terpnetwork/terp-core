# Security

> **IMPORTANT**: If you find a security issue, you can
report it to our core-team. *DO NOT* open a public issue on the repository.

## Bug Bounty

A Bug bounty program is needed to contrinute to minimize vulnerability breaches.

See the policy linked above for more details on submissions and rewards and read
this [blog post](https://blog.cosmos.network/bug-bounty-program-for-tendermint-cosmos-833c67693586) for the program scope. 

The following is a list of examples of the kinds of bugs we're most interested
in for the Terp-Core. See [here](https://github.com/tendermint/tendermint/blob/master/SECURITY.md) for vulnerabilities we are interested
in for Tendermint and other lower-level libraries (eg. [IAVL](https://github.com/cosmos/iavl)).

### Core packages

* [`/app`](https://github.com/terpnetwork/terp-core/tree/main/app)
* [`/proto`](https://github.com/terpnetwork/terp-core/tree/main/proto)
* [`/x`](https://github.com/terpnetwork/terp-core/tree/main/x)

### Modules


We are interested in bugs in other modules, however the above are most likely to
have significant vulnerabilities, due to the complexity / nuance involved. 

### How we process Tx parameters

* Integer operations on tx parameters, especially `sdk.Int` / `sdk.Dec`
* Gas calculation & parameter choices
* Possible Node DoS vectors (perhaps due to gas weighting / non constant timing)

### Handling private keys

* HD key derivation, local and Ledger, and all key-management functionality


## Disclosure Process

The TerpNET team uses the following disclosure process:

1. After a security report is received, the TerpNET team works to verify the issue and confirm its severity level using Common Vulnerability Scoring System (CVSS).
1. The TerpNET team collaborates with the Tendermint and Gaia teams to determine the vulnerability’s potential impact on the Cosmos Hub and partners.
1. Patches are prepared in private repositories for eligible releases of TerpNET. See [Stable Release Policy](https://github.com/cosmos/cosmos-sdk/blob/main/RELEASE_PROCESS.md#stable-release-policy) for a list of eligible releases.
1. If it is determined that a CVE-ID is required, we request a CVE through a CVE Numbering Authority.
1. We notify the community that a security release is coming to give users time to prepare their systems for the update. Notifications can include forum posts, tweets, and emails to partners and validators.
1. 24 hours after the notification, fixes are applied publicly and new releases are issued.
1. After releases are available for Cosmos-SDK, Terp-Core, and Tendermint, we notify the community again through the same channels. We also publish a Security Advisory on Github and publish the CVE, as long as the Security Advisory and the CVE do not include information on how to exploit these vulnerabilities beyond the information that is available in the patch.
1. After the community is notified, Tendermint pays out any relevant bug bounties to submitters.
1. One week after the releases go out, we publish a post with details and our response to the vulnerability.

This process can take some time. Every effort is made to handle the bug in as timely a manner as possible. However, it's important that we follow this security process to ensure that disclosures are handled consistently and to keep Terp-Core and its downstream dependent projects--including but not limited to Gaia and the Cosmos Hub--as secure as possible.

### Disclosure Communications

Communications to partners usually include the following details:

1. Affected version or versions
1. New release version
1. Impact on user funds
1. For timed releases, a date and time that the new release will be made available
1. Impact on the partners if upgrades are not completed in a timely manner
1. Potential required actions if an adverse condition arises during the security release process

An example notice looks like:

```text
Dear TerpNET partners,

A critical security vulnerability has been identified in Terp-Core vX.X.X.
User funds are NOT at risk; however, the vulnerability can result in a chain halt.

This notice is to inform you that on [[**March 1 at 1pm EST/6pm UTC**]], we will be releasing Terp-Core vX.X.Y to fix the security issue.
We ask all validators to upgrade their nodes ASAP.

If the chain halts, validators with sufficient voting power must upgrade and come online for the chain to resume.
```

### Example Timeline

The following timeline is an example of triage and response. Each task identifies the required roles and team members; however, multiple people can play each role and each person may play multiple roles.

#### 24+ Hours Before Release Time

1. Request CVE number (ADMIN)
1. Gather emails and other contact info for validators (COMMS LEAD)
1. Test fixes on a testnet  (Terp-Core ENG)
1. Write “Security Advisory” for forum (Terp-Core LEAD)

#### 24 Hours Before Release Time

1. Post “Security Advisory” pre-notification on forum (Terp-Core LEAD)
1. Post Tweet linking to forum post (COMMS LEAD)
1. Announce security advisory/link to post in various other social channels (Telegram, Discord) (COMMS LEAD)
1. Send emails to partners or other users (PARTNERSHIPS LEAD)

#### Release Time

1. Cut Terp-Core releases for eligible versions (Terp-Core ENG)
1. Cut Gaia release for eligible versions (GAIA ENG)
1. Post “Security releases” on forum (Terp-Core LEAD)
1. Post new Tweet linking to forum post (COMMS LEAD)
1. Remind everyone using social channels (Telegram, Discord)  that the release is out (COMMS LEAD)
1. Send emails to validators and other users (COMMS LEAD)
1. Publish Security Advisory and CVE if the CVE has no sensitive information (ADMIN)

#### After Release Time

1. Write forum post with exploit details (Terp-Core LEAD)
1. Approve payout on HackerOne for submitter (ADMIN)

#### 7 Days After Release Time

1. Publish CVE if it has not yet been published (ADMIN)
1. Publish forum post with exploit details (Terp-Core ENG, Terp-Core LEAD)