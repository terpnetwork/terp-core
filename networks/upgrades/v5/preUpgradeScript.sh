#!/bin/sh

# preUpgradeScript.sh - Called by cosmovisor to tweak config.toml before upgrade
# Purpose: Reduce block times by adjusting consensus timeouts for faster blocks

# Ensure DAEMON_HOME is set (set by cosmovisor)
if [ -z "$DAEMON_HOME" ]; then
  echo "ERROR: DAEMON_HOME is not set. This script must be run by cosmovisor." >&2
  exit 1
fi

CONFIG_PATH="$DAEMON_HOME/config/config.toml"

# Check if config file exists
if [ ! -f "$CONFIG_PATH" ]; then
  echo "ERROR: config.toml not found at $CONFIG_PATH" >&2
  exit 1
fi

# Backup original config (atomic, safe)
cp "$CONFIG_PATH" "$CONFIG_PATH.bak"
echo "Backup created: $CONFIG_PATH.bak"

# Update timeout_commit if it exists in [consensus] section
sed -i.bak "/^\[consensus\]/,/^\[/ s/^[[:space:]]*timeout_commit[[:space:]]*=.*/timeout_commit = \"2400ms\"/" "$CONFIG_PATH"

# Update timeout_propose if it exists in [consensus] section
sed -i.bak "/^\[consensus\]/,/^\[/ s/^[[:space:]]*timeout_propose[[:space:]]*=.*/timeout_propose = \"2400ms\"/" "$CONFIG_PATH"

# Remove the extra .bak files created by sed -i.bak (we only need one backup)
rm -f "$CONFIG_PATH.bak.bak"

echo "✅ Successfully updated consensus timeouts in $CONFIG_PATH"