#!/bin/bash
# init_two_chainz_relayer creates two terpd chains and configures the relayer

SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
TERPD_DATA="$(pwd)/data"
RELAYER_CONF="$(pwd)/.relayer"



# Display software version for testers
echo "TERPD VERSION INFO:"
terpd version --long

# Ensure jq is installed
if [[ ! -x "$(which jq)" ]]; then
  echo "jq (a tool for parsing json in the command line) is required..."
  echo "https://stedolan.github.io/jq/download/"
  exit 1
fi

# Delete data from old runs
rm -rf $TERPD_DATA &> /dev/null
rm -rf $RELAYER_CONF &> /dev/null

# Stop existing terpd processes
killall terpd &> /dev/null

set -e

chainid0=ibc-0
chainid1=ibc-1

echo "Generating terpd configurations..."
mkdir -p $TERPD_DATA && cd $TERPD_DATA && cd ../
./one_chain.sh terpd $chainid0 ./data 26657 26656 6060 9090
./one_chain.sh terpd $chainid1 ./data 26557 26556 6061 9091

[ -f $TERPD_DATA/$chainid0.log ] && echo "$chainid0 initialized. Watch file $TERPD_DATA/$chainid0.log to see its execution."
[ -f $TERPD_DATA/$chainid1.log ] && echo "$chainid1 initialized. Watch file $TERPD_DATA/$chainid1.log to see its execution."


echo "Generating rly configurations..."
rly config init
rly config add-chains configs/terpd/chains
rly config add-paths configs/terpd/paths

SEED0=$(jq -r '.mnemonic' $TERPD_DATA/ibc-0/key_seed.json)
SEED1=$(jq -r '.mnemonic' $TERPD_DATA/ibc-1/key_seed.json)
echo "Key $(rly keys restore ibc-0 testkey "$SEED0") imported from ibc-0 to relayer..."
echo "Key $(rly keys restore ibc-1 testkey "$SEED1") imported from ibc-1 to relayer..."
echo "Creating light clients..."
sleep 3
rly light init ibc-0 -f
rly light init ibc-1 -f
