// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";
import {IVRFCoordinatorV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/interfaces/IVRFCoordinatorV2Plus.sol";
import {LinkTokenInterface} from "@chainlink/contracts/src/v0.8/shared/interfaces/LinkTokenInterface.sol";
import {CodeConstants, HelperConfig} from "./HelperConfig.s.sol";
import {IVRFCoordinatorV2_5Mock} from "../test/mocks/IVRFCoordinatorV2_5Mock.sol";

/**
 * @title CreateSubscription
 * @author SonicWizard
 * @notice Creates a VRF subscription owned by the current chain's configured account.
 * @dev The coordinator derives the ID from the previous block hash, so on a live network the ID this script sees
 * while simulating is not the one created on-chain. Read the real ID from the broadcast transaction's
 * `SubscriptionCreated` event (`mise run sub:create:sepolia` does this), then fund it in a separate run.
 * Usage: forge script script/Interactions.s.sol:CreateSubscription --rpc-url <url> --account <acct> --broadcast
 */
contract CreateSubscription is Script {
    /**
     * @notice Creates a subscription on the current chain's coordinator.
     * @return subscriptionId The new subscription's ID, as seen by this run.
     */
    function run() external returns (uint256 subscriptionId) {
        HelperConfig.NetworkConfig memory config = new HelperConfig().getConfig();
        return createSubscription(config.vrfCoordinator, config.account);
    }

    /**
     * @notice Creates a subscription on `vrfCoordinator` owned by `account`.
     * @param vrfCoordinator The VRF coordinator to create the subscription on.
     * @param account The account that broadcasts and will own the subscription.
     * @return subscriptionId The new subscription's ID, as seen by this run.
     */
    function createSubscription(address vrfCoordinator, address account) public returns (uint256 subscriptionId) {
        vm.startBroadcast(account);
        subscriptionId = IVRFCoordinatorV2Plus(vrfCoordinator).createSubscription();
        vm.stopBroadcast();
        console.log("Created subscription (simulated ID):", subscriptionId);
    }
}

/**
 * @title FundSubscription
 * @author SonicWizard
 * @notice Adds LINK to a VRF subscription.
 * @dev On a live network this sends real LINK from the configured account via `transferAndCall`; locally it
 * credits the mock directly. Usage, with `amount` in LINK wei (1e18 = 1 LINK):
 * forge script script/Interactions.s.sol:FundSubscription --sig "run(uint256)" <amount> --rpc-url <url>
 * --account <acct> --broadcast
 */
contract FundSubscription is CodeConstants, Script {
    error FundSubscription__MissingSubscriptionId();
    error FundSubscription__TransferFailed();

    /**
     * @notice Funds the current chain's configured subscription.
     * @param amount The amount to add, in LINK wei.
     */
    function run(uint256 amount) external {
        HelperConfig helperConfig = new HelperConfig();
        HelperConfig.NetworkConfig memory config = helperConfig.getConfig();
        require(config.subscriptionId != 0, FundSubscription__MissingSubscriptionId());
        fundSubscription(config.vrfCoordinator, config.subscriptionId, config.link, amount, config.account);
    }

    /**
     * @notice Adds `amount` LINK to subscription `subscriptionId` on `vrfCoordinator`.
     * @param vrfCoordinator The VRF coordinator that holds the subscription.
     * @param subscriptionId The subscription to fund.
     * @param link The LINK token; unused on a local chain.
     * @param amount The amount to add, in LINK wei.
     * @param account The account that broadcasts and, on a live network, sends the LINK.
     */
    function fundSubscription(
        address vrfCoordinator,
        uint256 subscriptionId,
        address link,
        uint256 amount,
        address account
    ) public {
        vm.startBroadcast(account);
        if (block.chainid == LOCAL_CHAIN_ID) {
            IVRFCoordinatorV2_5Mock(vrfCoordinator).fundSubscription(subscriptionId, amount);
        } else {
            bool success = LinkTokenInterface(link).transferAndCall(vrfCoordinator, amount, abi.encode(subscriptionId));
            require(success, FundSubscription__TransferFailed());
        }
        vm.stopBroadcast();
        console.log("Funded subscription", subscriptionId, "with LINK wei:", amount);
    }
}

/**
 * @title AddConsumer
 * @author SonicWizard
 * @notice Registers a contract as a consumer of a VRF subscription.
 * @dev Only the subscription owner can add consumers, so the configured account must own the subscription.
 * Usage: forge script script/Interactions.s.sol:AddConsumer --sig "run(address)" <consumer> --rpc-url <url>
 * --account <acct> --broadcast
 */
contract AddConsumer is Script {
    error AddConsumer__MissingSubscriptionId();

    /**
     * @notice Adds `consumer` to the current chain's configured subscription.
     * @param consumer The contract that will request randomness, such as a deployed Raffle.
     */
    function run(address consumer) external {
        HelperConfig helperConfig = new HelperConfig();
        HelperConfig.NetworkConfig memory config = helperConfig.getConfig();
        require(config.subscriptionId != 0, AddConsumer__MissingSubscriptionId());
        addConsumer(config.vrfCoordinator, config.subscriptionId, consumer, config.account);
    }

    /**
     * @notice Adds `consumer` to subscription `subscriptionId` on `vrfCoordinator`. Does nothing if already added.
     * @param vrfCoordinator The VRF coordinator that holds the subscription.
     * @param subscriptionId The subscription to add the consumer to.
     * @param consumer The contract that will request randomness.
     * @param account The account that broadcasts; it must own the subscription.
     */
    function addConsumer(address vrfCoordinator, uint256 subscriptionId, address consumer, address account) public {
        vm.startBroadcast(account);
        IVRFCoordinatorV2Plus(vrfCoordinator).addConsumer(subscriptionId, consumer);
        vm.stopBroadcast();
        console.log("Added consumer", consumer, "to subscription", subscriptionId);
    }
}
