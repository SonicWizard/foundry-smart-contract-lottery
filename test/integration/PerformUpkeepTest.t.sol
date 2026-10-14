// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {DeployRaffle} from "../../script/DeployRaffle.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {PerformUpkeep} from "../../script/PerformUpkeep.s.sol";
import {Raffle} from "../../src/Raffle.sol";

contract PerformUpkeepTest is Test {
    Raffle private raffle;
    PerformUpkeep private performUpkeep;
    uint256 private interval;

    function setUp() external {
        HelperConfig helperConfig;
        (raffle, helperConfig) = new DeployRaffle().run();
        interval = helperConfig.getConfig().interval;
        performUpkeep = new PerformUpkeep();
    }

    function test_SkipsWhenUpkeepNotNeeded() external {
        uint256 lastTimeStamp = raffle.getLastTimeStamp();

        performUpkeep.run(address(raffle));

        assertEq(uint256(raffle.getRaffleState()), uint256(Raffle.RaffleState.OPEN));
        assertEq(raffle.getLastTimeStamp(), lastTimeStamp);
    }

    function test_PerformsUpkeepWhenNeeded() external {
        address player = makeAddr("player");
        hoax(player, raffle.getEntranceFee());
        raffle.enterRaffle{value: raffle.getEntranceFee()}();
        vm.warp(vm.getBlockTimestamp() + interval + 1);
        vm.roll(vm.getBlockNumber() + 1);

        performUpkeep.run(address(raffle));

        assertEq(uint256(raffle.getRaffleState()), uint256(Raffle.RaffleState.CALCULATING));
    }
}
