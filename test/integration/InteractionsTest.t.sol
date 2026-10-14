// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Vm} from "forge-std/Vm.sol";
import {IVRFCoordinatorV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/interfaces/IVRFCoordinatorV2Plus.sol";
import {LinkTokenInterface} from "@chainlink/contracts/src/v0.8/shared/interfaces/LinkTokenInterface.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {AddConsumer, CreateSubscription, FundSubscription} from "../../script/Interactions.s.sol";
import {SkipForkTest} from "../utils/SkipForkTest.sol";

contract InteractionsTest is SkipForkTest {
    uint256 private constant FUND_AMOUNT = 5 ether;
    uint256 private constant LIVE_SUBSCRIPTION_ID = 1;

    HelperConfig private helperConfig;
    address private vrfCoordinator;
    address private account;
    address private consumer = makeAddr("consumer");
    address private link = makeAddr("link");
    address private liveAccount = makeAddr("liveAccount");

    function setUp() external {
        helperConfig = new HelperConfig();
        HelperConfig.NetworkConfig memory config = helperConfig.getConfig();
        vrfCoordinator = config.vrfCoordinator;
        account = config.account;
    }

    function test_CreateFundAndAddConsumer() external skipFork {
        uint256 subscriptionId = new CreateSubscription().createSubscription(vrfCoordinator, account);
        new FundSubscription().fundSubscription(vrfCoordinator, subscriptionId, address(0), FUND_AMOUNT, account);
        new AddConsumer().addConsumer(vrfCoordinator, subscriptionId, consumer, account);

        (uint96 balance,,, address owner, address[] memory consumers) =
            IVRFCoordinatorV2Plus(vrfCoordinator).getSubscription(subscriptionId);
        assertEq(balance, FUND_AMOUNT);
        assertEq(owner, account);
        assertEq(consumers.length, 1);
        assertEq(consumers[0], consumer);
    }

    function test_RevertWhen_FundingWithoutSubscriptionId() external skipFork {
        FundSubscription fundSubscription = new FundSubscription();
        vm.expectRevert(FundSubscription.FundSubscription__MissingSubscriptionId.selector);
        fundSubscription.run(FUND_AMOUNT);
    }

    function test_RevertWhen_AddingConsumerWithoutSubscriptionId() external skipFork {
        AddConsumer addConsumer = new AddConsumer();
        vm.expectRevert(AddConsumer.AddConsumer__MissingSubscriptionId.selector);
        addConsumer.run(consumer);
    }

    function test_RunFundsAndAddsConsumerToConfiguredSubscription() external skipFork {
        HelperConfig.NetworkConfig memory config = helperConfig.getConfig();
        config.subscriptionId = new CreateSubscription().createSubscription(vrfCoordinator, account);
        FundSubscription fundSubscription = new FundSubscription();
        AddConsumer addConsumer = new AddConsumer();
        mockConfigOf(address(fundSubscription), config);
        mockConfigOf(address(addConsumer), config);

        fundSubscription.run(FUND_AMOUNT);
        addConsumer.run(consumer);

        (uint96 balance,,,, address[] memory consumers) =
            IVRFCoordinatorV2Plus(vrfCoordinator).getSubscription(config.subscriptionId);
        assertEq(balance, FUND_AMOUNT);
        assertEq(consumers.length, 1);
        assertEq(consumers[0], consumer);
    }

    function test_CreateSubscriptionRunUsesConfiguredCoordinator() external skipFork {
        vm.recordLogs();
        uint256 subscriptionId = new CreateSubscription().run();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // `run` deploys its own mock coordinator, so find the subscription through the event it emits.
        bytes32 subscriptionCreated = keccak256("SubscriptionCreated(uint256,address)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == subscriptionCreated) {
                assertEq(uint256(logs[i].topics[1]), subscriptionId);
                assertEq(abi.decode(logs[i].data, (address)), account);
                return;
            }
        }
        revert("SubscriptionCreated not emitted");
    }

    function test_FundSubscriptionSendsLinkOnLiveNetwork() external {
        vm.chainId(ETH_SEPOLIA_CHAIN_ID);
        bytes memory transferAndCall = abi.encodeCall(
            LinkTokenInterface.transferAndCall, (vrfCoordinator, FUND_AMOUNT, abi.encode(LIVE_SUBSCRIPTION_ID))
        );
        vm.mockCall(link, transferAndCall, abi.encode(true));

        vm.expectCall(link, transferAndCall);
        new FundSubscription().fundSubscription(vrfCoordinator, LIVE_SUBSCRIPTION_ID, link, FUND_AMOUNT, liveAccount);
    }

    function test_RevertWhen_LinkTransferFails() external {
        vm.chainId(ETH_SEPOLIA_CHAIN_ID);
        vm.mockCall(link, LinkTokenInterface.transferAndCall.selector, abi.encode(false));

        FundSubscription fundSubscription = new FundSubscription();
        vm.expectRevert(FundSubscription.FundSubscription__TransferFailed.selector);
        fundSubscription.fundSubscription(vrfCoordinator, LIVE_SUBSCRIPTION_ID, link, FUND_AMOUNT, liveAccount);
    }

    /// @dev A script's `run` deploys its own HelperConfig as the script's first contract, so mock `getConfig` at that
    /// address. `injectCode = false` keeps the address empty so the deployment still succeeds.
    function mockConfigOf(address script, HelperConfig.NetworkConfig memory config) private {
        address scriptHelperConfig = vm.computeCreateAddress(script, 1);
        vm.mockCall(scriptHelperConfig, abi.encodeCall(HelperConfig.getConfig, ()), abi.encode(config), false);
    }
}
