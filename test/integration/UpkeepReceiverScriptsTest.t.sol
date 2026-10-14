// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {DeployRaffle} from "../../script/DeployRaffle.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {DeployUpkeepReceiver, SetUpkeepForwarder} from "../../script/UpkeepReceiver.s.sol";
import {RaffleUpkeepReceiver} from "../../src/RaffleUpkeepReceiver.sol";
import {SkipForkTest} from "../utils/SkipForkTest.sol";

contract UpkeepReceiverScriptsTest is SkipForkTest {
    address private raffle;
    HelperConfig.NetworkConfig private config;

    function setUp() external {
        HelperConfig helperConfig;
        (, helperConfig) = new DeployRaffle().run();
        // Any address works as the target; the receiver only stores it.
        raffle = makeAddr("raffle");
        config = helperConfig.getConfig();
    }

    function test_DeployUsesProductionForwarder() external {
        RaffleUpkeepReceiver receiver = new DeployUpkeepReceiver().run(raffle, false);

        assertEq(receiver.getRaffle(), raffle);
        assertEq(receiver.getForwarder(), config.creForwarder);
        assertEq(receiver.owner(), config.account);
    }

    function test_DeployUsesSimulationForwarder() external {
        RaffleUpkeepReceiver receiver = new DeployUpkeepReceiver().run(raffle, true);

        assertEq(receiver.getForwarder(), config.creSimulationForwarder);
    }

    function test_SetUpkeepForwarderSwitchesForwarders() external {
        RaffleUpkeepReceiver receiver = new DeployUpkeepReceiver().run(raffle, true);
        SetUpkeepForwarder setUpkeepForwarder = new SetUpkeepForwarder();

        setUpkeepForwarder.run(address(receiver), false);
        assertEq(receiver.getForwarder(), config.creForwarder);

        setUpkeepForwarder.run(address(receiver), true);
        assertEq(receiver.getForwarder(), config.creSimulationForwarder);
    }

    function test_HelpersUseGivenForwarderAndAccount() external {
        address forwarder = makeAddr("forwarder");
        address newForwarder = makeAddr("newForwarder");
        address account = makeAddr("account");

        RaffleUpkeepReceiver receiver = new DeployUpkeepReceiver().deployUpkeepReceiver(raffle, forwarder, account);
        assertEq(receiver.getForwarder(), forwarder);
        assertEq(receiver.owner(), account);

        new SetUpkeepForwarder().setUpkeepForwarder(address(receiver), newForwarder, account);
        assertEq(receiver.getForwarder(), newForwarder);
    }
}
