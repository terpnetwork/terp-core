#!/usr/bin/env bash
set -euo pipefail

# submit_proposal.sh — Governance upgrade proposal submission
#
# This script will eventually automate the submission of a software upgrade
# governance proposal to the Terp Network via `terpd tx gov submit-proposal`.
#
# Future implementation will:
#   1. Accept parameters: upgrade name, height, tag, deposit amount, key name
#   2. Generate the binaries JSON using create_binaries_json.py
#   3. Fill in PROPOSAL_TEMPLATE.json with the provided values
#   4. Submit the proposal via:
#      terpd tx gov submit-proposal software-upgrade <name> \
#        --title "Upgrade to <name>" \
#        --description "..." \
#        --upgrade-height <height> \
#        --upgrade-info '<binaries_json>' \
#        --deposit <amount>uterp \
#        --from <key> \
#        --chain-id <chain-id> \
#        --yes

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ""
echo "=== Terp-Core Governance Proposal Submission ==="
echo ""
echo "STATUS: Not yet implemented"
echo ""
echo "This script will automate governance upgrade proposal submission."
echo "For now, please submit proposals manually using the terpd CLI."
echo ""
echo "Template available at:"
echo "  ${SCRIPT_DIR}/PROPOSAL_TEMPLATE.json"
echo ""
echo "Manual submission example:"
echo ""
echo "  terpd tx gov submit-proposal software-upgrade <upgrade-name> \\"
echo "    --title 'Upgrade to <version>' \\"
echo "    --description 'See changelog at https://github.com/terpnetwork/terp-core/releases' \\"
echo "    --upgrade-height <block-height> \\"
echo "    --upgrade-info '<binaries-json>' \\"
echo "    --deposit 10000000uterp \\"
echo "    --from <your-key> \\"
echo "    --chain-id morocco-1 \\"
echo "    --yes"
echo ""
echo "TODO: Implement automated proposal submission"
echo ""
