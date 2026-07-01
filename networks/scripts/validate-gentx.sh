#!/bin/sh
TERPD_HOME="/tmp/terpd$(date +%s)"
RANDOM_KEY="randomterpdvalidatorkey"
CHAIN_ID=morocco-1
GAS_DENOM=uthiol
GOV_DENOM=uterp
# MAXBOND=10000000 # 1terp
GENTX_FILE=$(find ./$CHAIN_ID/gentx -iname "*.json")
LEN_GENTX=$(echo ${#GENTX_FILE})

# Gentx Start date
start="2022-04-10T12:00:00Zz"
# Compute the seconds since epoch for start date
stTime=$(date --date="$start" +%s)

# Gentx End date
end="2023-04-05 12:00:00Z"
# Compute the seconds since epoch for end date
endTime=$(date --date="$end" +%s)

# Current date
current=$(date +%Y-%m-%d\ %H:%M:%S)
# Compute the seconds since epoch for current date
curTime=$(date --date="$current" +%s)

if [[ $curTime < $stTime ]]; then
    echo "start=$stTime:curent=$curTime:endTime=$endTime"
    echo "Gentx submission is not open yet."
    exit 1
else
    if [[ $curTime > $endTime ]]; then
        echo "start=$stTime:curent=$curTime:endTime=$endTime"
        echo "Gentx submission is closed"
        exit 1
    else
        echo "Gentx is now open"
        echo "start=$stTime:curent=$curTime:endTime=$endTime"
    fi
fi

if [ $LEN_GENTX -eq 0 ]; then
    echo "No new gentx file found."
    exit 0
else
    set -e

    echo "GentxFiles::::"
    echo $GENTX_FILE

    echo "...........Init Terp Network.............."

    git clone https://github.com/terpnetwork/terp-core
    cd terp-core
    git checkout morocco-1
    make build
    chmod +x ./bin/terpd

    ./bin/terpd keys add $RANDOM_KEY --keyring-backend test --home $TERPD_HOME

    ./bin/terpd init --chain-id $CHAIN_ID validator --home $TERPD_HOME

    echo "..........Fetching genesis......."
    rm -rf $TERPD_HOME/config/genesis.json
    curl -s  https://raw.githubusercontent.com/terpnetwork/mainnet/main/$CHAIN_ID/pre-genesis.json >$TERPD_HOME/config/genesis.json

    # this genesis time is different from original genesis time, just for validating gentx.
    sed -i '/genesis_time/c\   \"genesis_time\" : \"2021-09-02T16:00:00Z\",' $TERPD_HOME/config/genesis.json

    find ../$CHAIN_ID/gentx -iname "*.json" -print0 |
        while IFS= read -r -d '' line; do
            GENACC=$(cat $line | sed -n 's|.*"delegator_address":"\([^"]*\)".*|\1|p')
            denomquery=$(jq -r '.body.messages[0].value.denom' $line)
            amountquery=$(jq -r '.body.messages[0].value.amount' $line)

            echo $GENACC
            echo $amountquery
            echo $denomquery

            # only allow $DENOM tokens to be bonded
            if [ $denomquery != $GOV_DENOM ]; then
                echo "invalid denomination"
                exit 1
            fi
        done

    # # limit the amount that can be bonded?
    # if [ $amountquery -gt $MAXBOND ]; then
    #     echo "bonded too much: $amountquery > $MAXBOND"
    #     exit 1
    # fi

    mkdir -p $TERPD_HOME/config/gentx/
    cp -r ../$CHAIN_ID/gentx/* $TERPD_HOME/config/gentx/

    echo "..........Collecting gentxs......."
    ./bin/terpd collect-gentxs --home $TERPD_HOME &> log.txt
    sed -i '/persistent_peers =/c\persistent_peers = ""' $TERPD_HOME/config/config.toml
    sed -i '/minimum-gas-prices =/c\minimum-gas-prices = "0.25uthiol"' $TERPD_HOME/config/app.toml

    ./bin/terpd validate-genesis --home $TERPD_HOME

    echo "..........Starting node......."
    ./bin/terpd start --home $TERPD_HOME &

    sleep 90s

    echo "...checking network status.."

    ./bin/terpd status --node http://localhost:26657

    echo "...Cleaning the stuff..."
    killall terpd >/dev/null 2>&1
    rm -rf $TERPD_HOME >/dev/null 2>&1
fi
