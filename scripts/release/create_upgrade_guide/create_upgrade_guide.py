import argparse
import os
import re
import sys
from string import Template

# USAGE:
#
# This script generates a Mainnet Upgrade Guide using a template. It replaces variables like current_version, upgrade_version,
# proposal_id, and upgrade_block based on the arguments provided.
#
# Example (coordinated upgrade):
# python create_upgrade_guide.py --type coordinated --current_version=v18 --upgrade_version=v19 --proposal_id=606 --upgrade_block=11317300 --upgrade_tag=v19.0.0
#
# Example (rolling upgrade):
# python create_upgrade_guide.py --type rolling --current_version=v18 --upgrade_version=v19 --upgrade_tag=v19.0.0
#
# Arguments:
# --type                : Guide type: 'rolling' or 'coordinated' (default: coordinated)
# --current_version     : The current version before upgrade (e.g., v18)
# --upgrade_version     : The version to upgrade to (e.g., v19)
# --proposal_id         : The proposal ID related to the upgrade (coordinated only)
# --upgrade_block       : The block height at which the upgrade will occur (coordinated only)
# --upgrade_tag         : The specific version tag for the upgrade (e.g., v19.0.0)


SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

TEMPLATES = {
    "coordinated": os.path.join(SCRIPT_DIR, "UPGRADE_TEMPLATE.md"),
    "rolling": os.path.join(SCRIPT_DIR, "ROLLING_UPGRADE_TEMPLATE.md"),
}


def validate_tag(tag):
    pattern = '^v[0-9]+.[0-9]+.[0-9]+$'
    return bool(re.match(pattern, tag))


def validate_version(version):
    pattern = '^v\d+$'
    return bool(re.match(pattern, version))


def main():
    parser = argparse.ArgumentParser(description="Create upgrade guide from template")
    parser.add_argument('--type', metavar='type', type=str, default='coordinated',
                        choices=['rolling', 'coordinated'],
                        help='Guide type: rolling or coordinated (default: coordinated)')
    parser.add_argument('--current_version', '-c', metavar='current_version', type=str, required=True,
                        help='Current version (e.g v1)')
    parser.add_argument('--upgrade_version', '-u', metavar='upgrade_version', type=str, required=True,
                        help='Upgrade version (e.g v2)')
    parser.add_argument('--upgrade_tag', '-t', metavar='upgrade_tag', type=str, required=True,
                        help='Upgrade tag (e.g v2.0.0)')
    parser.add_argument('--proposal_id', '-p', metavar='proposal_id', type=str, required=False,
                        help='Proposal ID (required for coordinated upgrades)')
    parser.add_argument('--upgrade_block', '-b', metavar='upgrade_block', type=str, required=False,
                        help='Upgrade block height (required for coordinated upgrades)')

    args = parser.parse_args()

    if args.type == 'coordinated':
        if not args.proposal_id:
            parser.error("--proposal_id is required for coordinated upgrades")
        if not args.upgrade_block:
            parser.error("--upgrade_block is required for coordinated upgrades")

    if not validate_version(args.current_version):
        print("Error: The provided current_version does not follow the 'vX' format.")
        sys.exit(1)

    if not validate_version(args.upgrade_version):
        print("Error: The provided upgrade_version does not follow the 'vX' format.")
        sys.exit(1)

    if not validate_tag(args.upgrade_tag):
        print("Error: The provided tag does not follow the 'vX.Y.Z' format.")
        sys.exit(1)

    template_path = TEMPLATES[args.type]
    with open(template_path, 'r') as f:
        markdown_template = f.read()

    t = Template(markdown_template)

    substitutions = {
        'CURRENT_VERSION': args.current_version,
        'UPGRADE_VERSION': args.upgrade_version,
        'UPGRADE_TAG': args.upgrade_tag,
    }

    if args.type == 'coordinated':
        substitutions['PROPOSAL_ID'] = args.proposal_id
        substitutions['UPGRADE_BLOCK'] = args.upgrade_block

    filled_markdown = t.safe_substitute(**substitutions)
    print(filled_markdown)


if __name__ == "__main__":
    main()
