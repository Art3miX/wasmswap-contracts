#!/bin/bash
set -e -x

# Run this from the scripts directory

# First argument is the Pool address, second argument is the staking contract of the same pool address.
# Example: `./add_liquidity.sh juno1gjk9gva6dfs254qvlthw6ldqu3etp3wf2854n2ln7szepzvrggys89w3yn juno1paazsk7v2sx8tdjgw9ud22mg6hrawqwd27tjrv4nex9v529yzphsglem68`

## CONFIG
BINARY='docker exec -i cosmwasm junod'
DENOM='ujunox'
CHAIN_ID='uni-5'
RPC='https://rpc.uni.junonetwork.io:443'
TXFLAG="--gas-prices 0.1$DENOM --gas auto --gas-adjustment 1.3 -y -b block --chain-id $CHAIN_ID --node $RPC"
QFLAG="--chain-id $CHAIN_ID --node $RPC"
TESTER_MNEMONIC='siren window salt bullet cream letter huge satoshi fade shiver permit offer happy immense wage fitness goose usual aim hammer clap about super trend'
PASS='12345678'
FAUCET_ADDR='juno12gqyglvj4rdg4kcc292s8z7u25d3s4tuph98y8'
KILL_DOCKER='docker kill cosmwasm'

if [ "$1" = "" ]
then
  echo "Usage: $0 2 args required, 1st argument LP address is missing!"
  exit
elif [ "$2" = "" ]
then
  echo "Usage: $0 2 args required, 2nd argument Staking address is missing!"
  exit
fi

# Start docker with junod installed
$KILL_DOCKER &>/dev/null || true 

docker run --rm -d -t --name cosmwasm \
    --mount type=volume,source=junod_data,target=/root \
    --platform linux/amd64 \
    ghcr.io/cosmoscontracts/juno:v11.0.0 sh

# Try to delete faucet if already exists
echo $PASS | $BINARY keys delete faucet -y &>/dev/null || true 

# Add faucet wallet
(echo $TESTER_MNEMONIC; echo $PASS; echo $PASS) | $BINARY keys add faucet --account 1 --recover > /dev/null

# LP Data, like pool address, staking address, the cw20 addresses.
POOL_ADDR=$1
STAKING_ADDR=$2

LP_RESPONSE=$($BINARY q wasm contract-state smart $POOL_ADDR '{"info":{}}' --output json $QFLAG | jq -r '.data')
TOKEN_1_ADDR=$(echo $LP_RESPONSE | jq -r '.token1_denom | select(.cw20 != null) | .cw20')
TOKEN_2_ADDR=$(echo $LP_RESPONSE | jq -r '.token2_denom | select(.cw20 != null) | .cw20')
LP_TOKEN_ADDR=$(echo $LP_RESPONSE | jq -r '.lp_token_address')

# echo $LP_RESPONSE
# echo $TOKEN_1_ADDR $TOKEN_2_ADDR $LP_TOKEN_ADDR

BASE_NAME="ws-tester"

# NOTE: Important to start from index 2, because index 0 is our manual tester, index 1 is our faucet
for INDEX in {22..22}
do
  TESTER_NAME=$BASE_NAME"-"$INDEX
  echo $TESTER_NAME

  AMT1=$((INDEX * 100))
  AMT2=$((INDEX * 160))

  # Add tester address to junod
  echo $PASS | $BINARY keys delete $TESTER_NAME -y &>/dev/null || true 
  (echo $TESTER_MNEMONIC; echo $PASS; echo $PASS) | $BINARY keys add $TESTER_NAME --account $INDEX --recover >/dev/null
  TESTER_ADDR=$(echo $PASS | $BINARY keys show $TESTER_NAME --address)

  # Use bank to fund wallet from faucet (for gas and pool)
  echo $PASS | $BINARY tx bank send faucet $TESTER_ADDR 100000ujunox $TXFLAG >/dev/null

  if [ -n "$TOKEN_1_ADDR" ]
  then
    # CW20 token, use transfer to fund wallet from faucet
    echo $PASS | $BINARY tx wasm execute $TOKEN_1_ADDR '{"transfer":{"recipient":"'"$TESTER_ADDR"'","amount":"'"$AMT1"'"}}' --from faucet $TXFLAG >/dev/null
    TOKEN_ADDR=$TOKEN_1_ADDR
  else
    # Its native token, we need to add funds (--amount)
    FUNDS="--amount ${AMT1}ujunox"
  fi

  if [ -n "$TOKEN_2_ADDR" ]
  then
    # CW20 token, use transfer to fund wallet from faucet
    echo $PASS | $BINARY tx wasm execute $TOKEN_2_ADDR '{"transfer":{"recipient":"'"$TESTER_ADDR"'","amount":"'"$AMT2"'"}}' --from faucet $TXFLAG >/dev/null
    TOKEN_ADDR=$TOKEN_2_ADDR
  else
    # Its native token, we need to add funds (--amount)
    FUNDS="--amount ${AMT2}ujunox"
  fi

  # increase allowance
  echo $PASS | $BINARY tx wasm execute $TOKEN_ADDR '{"increase_allowance":{"amount":"20000","spender":"'"$POOL_ADDR"'"}}' --from $TESTER_NAME $TXFLAG >/dev/null

  # Add liquidity
  echo $PASS | $BINARY tx wasm execute $POOL_ADDR '{"add_liquidity":{"token1_amount":"'"$AMT1"'","min_liquidity":"1","max_token2":"'"$AMT2"'"}}' --from $TESTER_NAME $FUNDS $TXFLAG >/dev/null

  # Query available LP shares
  LP_BALANCE=$($BINARY query wasm contract-state smart $LP_TOKEN_ADDR '{"balance":{"address":"'"$TESTER_ADDR"'"}}' --output json $QFLAG | jq -r '.data.balance')
  # Stake
  staking_msg=`echo '{"stake":{}}' | base64`
  echo $PASS | $BINARY tx wasm execute $LP_TOKEN_ADDR '{"send":{"contract":"'"$STAKING_ADDR"'","amount":"'"$LP_BALANCE"'","msg":"'"$staking_msg"'"}}' --from $TESTER_NAME $TXFLAG >/dev/null

  # unbond a few
  UNBOND=$((LP_BALANCE / 3))
  echo $PASS | $BINARY tx wasm execute $STAKING_ADDR '{"unstake":{"amount":"'"$UNBOND"'"}}' --from $TESTER_NAME $TXFLAG >/dev/null

  # Increase index
  let INDEX=INDEX+1

  echo $TESTER_NAME" finished successfully!"
done

$KILL_DOCKER


# Swap msg for native denom
# $BINARY tx wasm execute $POOL_ADDR '{"swap":{"input_token": "Token2","input_amount":"2000000","min_output":"1"}}' --from faucet --amount 2000000ujunox $TXFLAG
