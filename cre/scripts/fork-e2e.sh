#!/usr/bin/env bash
# End-to-end check of the CRE upkeep path on a local Anvil fork of Sepolia. Nothing is sent to Sepolia.
#
# Deploys a Raffle and a RaffleUpkeepReceiver (simulation forwarder), enters a player, moves time past the interval
# and finality, then runs the real CRE simulator with --broadcast against the fork. Passes if the report triggered
# upkeep and a second, stale report was skipped.
#
# Needs `mise run cre:fork` running in another terminal. Run it with `mise run cre:e2e:fork`.
set -euo pipefail

RPC=http://127.0.0.1:8546
# Anvil's first two prefunded accounts. Their keys are public; they only ever touch the local fork.
ANVIL_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
PLAYER=0x70997970C51812dc3A010C7d01b50e8d17dc79C8
# Anvil treats a block as finalized 64 blocks later, and CRE reads at the finalized block.
BLOCKS_PAST_FINALITY=0x50

cd "$(dirname "$0")/../.."

if ! cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; then
    echo "No fork on $RPC. Start one with: mise run cre:fork" >&2
    exit 1
fi

account=$(grep -E '^SEPOLIA_ACCOUNT=' .env | cut -d= -f2 | tr -d '"')
if [ -z "$account" ]; then
    echo "Set SEPOLIA_ACCOUNT in .env; the fork impersonates it to use your VRF subscription." >&2
    exit 1
fi

# Keep Forge's logs for these fork deployments out of broadcast/, where they would overwrite real Sepolia ones.
FOUNDRY_BROADCAST=$(mktemp -d)
export FOUNDRY_BROADCAST
config=cre/raffle-upkeep/config.fork.json
trap 'rm -rf "$FOUNDRY_BROADCAST" "$config"' EXIT

echo "Deploying Raffle and RaffleUpkeepReceiver on the fork..."
forge script script/DeployRaffle.s.sol --rpc-url "$RPC" --broadcast --unlocked --sender "$account" --quiet
raffle=$(jq -r '.transactions[] | select(.contractName == "Raffle") | .contractAddress' \
    "$FOUNDRY_BROADCAST/DeployRaffle.s.sol/11155111/run-latest.json")
forge script script/UpkeepReceiver.s.sol:DeployUpkeepReceiver --sig "run(address,bool)" "$raffle" true \
    --rpc-url "$RPC" --broadcast --unlocked --sender "$account" --quiet
receiver=$(jq -r '.transactions[] | select(.contractName == "RaffleUpkeepReceiver") | .contractAddress' \
    "$FOUNDRY_BROADCAST/UpkeepReceiver.s.sol/11155111/run-latest.json")
echo "Raffle $raffle, receiver $receiver"

echo "Entering a player and moving past the interval and finality..."
cast rpc anvil_setBalance "$PLAYER" 0xDE0B6B3A7640000 --rpc-url "$RPC" >/dev/null
cast send "$raffle" "enterRaffle()" --value 0.01ether --from "$PLAYER" --unlocked --rpc-url "$RPC" >/dev/null
cast rpc evm_increaseTime 31 --rpc-url "$RPC" >/dev/null
cast rpc anvil_mine "$BLOCKS_PAST_FINALITY" --rpc-url "$RPC" >/dev/null

cat >"$config" <<EOF
{
  "chainSelectorName": "ethereum-testnet-sepolia",
  "raffleAddress": "$raffle",
  "receiverAddress": "$receiver",
  "schedule": "0 */1 * * * *",
  "writeGasLimit": "500000"
}
EOF

# Runs the workflow once and prints the report transaction hash, if it sent one.
simulate() {
    (cd cre && CRE_ETH_PRIVATE_KEY=$ANVIL_KEY cre workflow simulate raffle-upkeep --target fork-settings \
        --non-interactive --trigger-index 0 --broadcast 2>&1) | grep -oE "Upkeep report sent: 0x[0-9a-f]{64}" |
        grep -oE "0x[0-9a-f]{64}" || true
}

# Prints which receiver events a transaction emitted.
receiver_events() {
    local performed skipped emitter
    performed=$(cast keccak "UpkeepPerformed()")
    skipped=$(cast keccak "UpkeepSkipped()")
    emitter=$(echo "$receiver" | tr '[:upper:]' '[:lower:]')
    cast receipt "$1" --json --rpc-url "$RPC" | jq -r --arg r "$emitter" --arg p "$performed" --arg s "$skipped" \
        '.logs[] | select(.address == $r) | .topics[0]
         | if . == $p then "UpkeepPerformed" elif . == $s then "UpkeepSkipped" else empty end'
}

echo "Running the CRE workflow (upkeep is due)..."
tx=$(simulate)
[ -n "$tx" ] || { echo "FAIL: the workflow sent no report" >&2; exit 1; }
[ "$(receiver_events "$tx")" = "UpkeepPerformed" ] || { echo "FAIL: report $tx did not perform upkeep" >&2; exit 1; }
[ "$(cast call "$raffle" "getRaffleState()(uint8)" --rpc-url "$RPC")" = "1" ] ||
    { echo "FAIL: the raffle is not CALCULATING" >&2; exit 1; }
echo "  report $tx performed upkeep; the raffle is CALCULATING"

echo "Running it again (the finalized block is stale, so the receiver should skip)..."
tx=$(simulate)
[ -n "$tx" ] || { echo "FAIL: the workflow sent no report" >&2; exit 1; }
[ "$(receiver_events "$tx")" = "UpkeepSkipped" ] || { echo "FAIL: stale report $tx was not skipped" >&2; exit 1; }
echo "  report $tx was skipped"

echo "PASS"
