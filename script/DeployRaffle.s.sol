// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {CodeConstants, HelperConfig} from "./HelperConfig.s.sol";
import {AddConsumer, CreateSubscription, FundSubscription} from "./Interactions.s.sol";
import {Raffle} from "../src/Raffle.sol";

/**
 * @title DeployRaffle
 * @author SonicWizard
 * @notice Deploys a Raffle and registers it as a consumer of the VRF subscription.
 * @dev If no subscription is configured, it creates and funds one on the local mock, but only when nothing is
 * broadcast (tests, or `forge script` without `--broadcast`). A subscription created during a broadcast gets a
 * different ID on-chain than in simulation (see `CreateSubscription`), so funding and using it in the same run would
 * fail. On a real node, Anvil included, create and fund the subscription first.
 * Usage: forge script script/DeployRaffle.s.sol --rpc-url <url> --account <acct> --broadcast
 * `<acct>` must be the chain's configured account (see `HelperConfig`), which must own the VRF subscription.
 */
contract DeployRaffle is CodeConstants, Script {
    error DeployRaffle__MissingSubscriptionId();

    /**
     * @notice Deploys the Raffle with the current chain's config.
     * @return raffle The deployed Raffle.
     * @return helperConfig The config used, so callers can read the same values.
     */
    function run() external returns (Raffle raffle, HelperConfig helperConfig) {
        helperConfig = new HelperConfig();
        HelperConfig.NetworkConfig memory config = helperConfig.getConfig();

        if (config.subscriptionId == 0) {
            require(
                block.chainid == LOCAL_CHAIN_ID && !vm.isContext(VmSafe.ForgeContext.ScriptBroadcast),
                DeployRaffle__MissingSubscriptionId()
            );
            config.subscriptionId = new CreateSubscription().createSubscription(config.vrfCoordinator, config.account);
            new FundSubscription()
                .fundSubscription(
                    config.vrfCoordinator,
                    config.subscriptionId,
                    config.link,
                    LOCAL_SUBSCRIPTION_FUND_AMOUNT,
                    config.account
                );
        }

        vm.startBroadcast(config.account);
        raffle = new Raffle(
            config.entranceFee,
            config.interval,
            config.vrfCoordinator,
            config.gasLane,
            config.subscriptionId,
            config.callbackGasLimit
        );
        vm.stopBroadcast();

        new AddConsumer().addConsumer(config.vrfCoordinator, config.subscriptionId, address(raffle), config.account);
    }
}
