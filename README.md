# Smart Contract Lottery

A provably fair raffle built with [Foundry](https://getfoundry.sh/), using
[Chainlink VRF v2.5](https://docs.chain.link/vrf) for randomness. Based on the lottery project in Cyfrin Updraft's
[Foundry Fundamentals](https://updraft.cyfrin.io/courses/foundry) course.

## How it works

1. Players call `enterRaffle` and pay the entrance fee (0.01 ETH).
2. Once the interval (30 seconds) has passed and the raffle has players and ETH, `checkUpkeep` returns true.
3. Anyone can then call `performUpkeep`. It closes entries (the raffle state becomes `CALCULATING`) and requests a
   random number from the VRF coordinator.
4. The coordinator calls back `fulfillRandomWords`, which picks the winner, resets the raffle for the next round and
   sends the winner the whole balance.

Chainlink Automation isn't used to call `performUpkeep`. Run the `PerformUpkeep` script (`mise run upkeep:sepolia`)
or call it with `cast` instead.

| Path | Contents |
| --- | --- |
| `src/Raffle.sol` | The raffle contract |
| `script/HelperConfig.s.sol` | Per-chain settings: VRF coordinator, gas lane, subscription, LINK token, broadcasting account |
| `script/DeployRaffle.s.sol` | Deploys the raffle and adds it as a consumer of the VRF subscription |
| `script/Interactions.s.sol` | Create, fund and add consumers to a VRF subscription |
| `script/PerformUpkeep.s.sol` | Triggers `performUpkeep` if `checkUpkeep` says it's needed |
| `test/unit`, `test/integration` | Tests; `test/integration/RaffleFlowTest.t.sol` runs whole rounds end to end |

## Requirements

- [Foundry](https://getfoundry.sh/)
- [mise](https://mise.jdx.dev/), which runs the project tasks in `mise.toml` (`mise tasks` lists them)
- For Sepolia only:
  - the [1Password CLI](https://developer.1password.com/docs/cli/) (`op`), which supplies the RPC URL and Etherscan API
    key
  - an [Etherscan API key](https://etherscan.io/myapikey) (free), to verify the deployed contract
  - `jq`, used by `mise run sub:create:sepolia`
  - a Foundry keystore account (`cast wallet import`) with Sepolia ETH and LINK
    ([faucet](https://faucets.chain.link/sepolia))

## Setup

```shell
git clone --recurse-submodules https://github.com/SonicWizard/foundry-smart-contract-lottery.git
cd foundry-smart-contract-lottery
mise run build
```

Local builds and tests need nothing else. For Sepolia, copy `.env.example` to `.env` and fill it in:

| Variable | Value |
| --- | --- |
| `SEPOLIA_RPC_URL` | A [1Password secret reference](https://developer.1password.com/docs/cli/secret-references/) to your RPC URL, such as `op://Dev/Alchemy/sepolia-url` |
| `ETHERSCAN_API_KEY` | A 1Password secret reference to your Etherscan API key |
| `SEPOLIA_ACCOUNT` | The address of your keystore account. It owns the VRF subscription and pays its LINK, and the scripts broadcast from it on Sepolia. |
| `SEPOLIA_SUBSCRIPTION_ID` | Your VRF subscription ID. Leave it empty until you create one (see below). |

`.env` is ignored by git. The Sepolia tasks run through `op run --env-file=.env`, which reads the secrets only for
that command. Check the RPC URL with `mise run rpc:check`, which should print `11155111`.

## Testing

```shell
mise run test       # all tests on a local chain, using Chainlink's VRF coordinator mock
mise run test:fork  # the same tests against a fork of Sepolia
mise run coverage   # coverage summary
mise run check      # what CI runs: forge fmt --check, forge build --sizes, forge test
```

On a fork, the 8 tests that need the local VRF mock are reported as skipped. The rest deploy against the real Sepolia
coordinator and your subscription, so `SEPOLIA_SUBSCRIPTION_ID` and `SEPOLIA_ACCOUNT` must be set.

## Deploying to Sepolia

Each task takes `<account>`, the name of your Foundry keystore account. It must hold the key for `SEPOLIA_ACCOUNT`, or
Forge refuses to broadcast.

1. **Create a subscription**, then set `SEPOLIA_SUBSCRIPTION_ID` in `.env` to the ID it prints:

   ```shell
   mise run sub:create:sepolia <account>
   ```

   Forge's simulated run logs a different ID from the real one; the task reads the real ID from the transaction.

2. **Fund it with LINK**, for example 5 LINK:

   ```shell
   mise run sub:fund:sepolia 5 <account>
   ```

3. **Deploy the raffle.** This also adds it as a consumer of the subscription and verifies the source on Etherscan:

   ```shell
   mise run deploy:sepolia <account>
   ```

   If `ETHERSCAN_API_KEY` is missing, the task stops before sending anything. If the deployment succeeds but
   verification fails (Etherscan can be slow to index a new contract), verify it again without redeploying:

   ```shell
   op run --env-file=.env -- forge verify-contract <raffle-address> src/Raffle.sol:Raffle --chain sepolia \
     --rpc-url sepolia --guess-constructor-args --verifier etherscan --watch
   ```

4. **Enter** from any account:

   ```shell
   op run --env-file=.env -- cast send <raffle-address> "enterRaffle()" --value 0.01ether \
     --rpc-url sepolia --account <account>
   ```

5. **Pick a winner** once the interval has passed. The coordinator calls back a few blocks later:

   ```shell
   mise run upkeep:sepolia <raffle-address> <account>
   ```

To add an existing raffle to the subscription again, run `mise run sub:add-consumer:sepolia <raffle-address> <account>`.

Deploying to a local Anvil node isn't supported. The local config has no subscription ID, and `DeployRaffle` only
creates one when nothing is broadcast, so locally the raffle runs only inside tests.

## Differences from the course

- **Tasks:** `mise` tasks instead of a Makefile, with secrets supplied by 1Password through `op run` instead of being
  stored in `.env`.
- **Upkeep:** triggered with the `PerformUpkeep` script instead of registering the raffle with Chainlink Automation.
- **Local funding:** no solmate or `LinkToken` mock. Locally, the mock coordinator's `fundSubscription` credits the
  subscription directly; only Sepolia uses LINK's `transferAndCall`.
- **VRF coordinator calls:** scripts call through Chainlink's `IVRFCoordinatorV2Plus` interface instead of the mock's
  type, and the mock is deployed with `deployCode`. Chainlink pins the mock to Solidity 0.8.19, so this project's
  `^0.8.27` code can't import it.
- **Broadcasting account:** read from `SEPOLIA_ACCOUNT` in `.env` instead of being hard-coded in `HelperConfig`, and
  checked before any script runs on Sepolia.
- **Adding a consumer:** `AddConsumer` takes the raffle address as an argument instead of finding the latest
  deployment with `foundry-devops`, so no `fs_permissions` are needed.
- **Tests:** every script is tested, a two-round end-to-end test runs whole rounds with several players, and coverage
  is 100% for lines and branches. Tests that need the local VRF mock are reported as skipped on a fork rather than
  passing without running.

## Known issues

### A winner that can't receive ETH stops the raffle

`fulfillRandomWords` sends the prize straight to the winner and reverts with `Raffle__TransferFailed` if that send
fails. A contract with no `receive` or `fallback` function can enter the raffle, either by mistake or on purpose. If
it wins, the callback reverts, so the players, timestamp and state are never reset. The raffle then stays in
`CALCULATING` for good: no one can enter, and `checkUpkeep` never returns true again. The prize is locked in the
contract.

`test_RevertWhen_WinnerRejectsPayment` in `test/unit/RaffleTest.t.sol` reproduces this.

**Fix to make before a real deployment:** switch from sending the prize to letting the winner withdraw it.
`fulfillRandomWords` would record the winner's balance and reset the round without making any external call. A
separate `withdraw` function would then pay out, so a failed payment affects only that winner.
