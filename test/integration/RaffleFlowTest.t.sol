// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Vm} from "forge-std/Vm.sol";
import {DeployRaffle} from "../../script/DeployRaffle.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {PerformUpkeep} from "../../script/PerformUpkeep.s.sol";
import {Raffle} from "../../src/Raffle.sol";
import {IVRFCoordinatorV2_5Mock} from "../mocks/IVRFCoordinatorV2_5Mock.sol";
import {SkipForkTest} from "../utils/SkipForkTest.sol";

/// @dev Runs whole raffle rounds the way they happen in practice: deploy script, entries, upkeep script, VRF answer.
contract RaffleFlowTest is SkipForkTest {
    uint256 private constant STARTING_PLAYER_BALANCE = 10 ether;
    uint256 private constant FIRST_ROUND_PLAYERS = 4;
    uint256 private constant SECOND_ROUND_NEW_PLAYERS = 2;

    Raffle private raffle;
    PerformUpkeep private performUpkeep;
    IVRFCoordinatorV2_5Mock private vrfCoordinator;
    uint256 private entranceFee;
    uint256 private interval;

    function setUp() external {
        HelperConfig helperConfig;
        (raffle, helperConfig) = new DeployRaffle().run();
        HelperConfig.NetworkConfig memory config = helperConfig.getConfig();
        vrfCoordinator = IVRFCoordinatorV2_5Mock(config.vrfCoordinator);
        entranceFee = config.entranceFee;
        interval = config.interval;
        performUpkeep = new PerformUpkeep();
    }

    function test_RunsTwoRoundsWithMultiplePlayers() external skipFork {
        // DeployRaffle created the mock's only subscription, funded it and registered the raffle on it.
        uint256 subscriptionId = vrfCoordinator.getActiveSubscriptionIds(0, 1)[0];
        (uint96 subscriptionBalance,,,, address[] memory consumers) = vrfCoordinator.getSubscription(subscriptionId);
        assertEq(subscriptionBalance, LOCAL_SUBSCRIPTION_FUND_AMOUNT);
        assertEq(consumers.length, 1);
        assertEq(consumers[0], address(raffle));

        address[] memory firstRound = newPlayers("first", FIRST_ROUND_PLAYERS);
        address firstWinner = playRound(firstRound, 2, subscriptionId);

        // The first winner plays again with new players and wins only this round's prize, so nothing from round one
        // (players or ETH) may be left behind.
        address[] memory newcomers = newPlayers("second", SECOND_ROUND_NEW_PLAYERS);
        address[] memory secondRound = new address[](SECOND_ROUND_NEW_PLAYERS + 1);
        secondRound[0] = firstWinner;
        for (uint256 i = 0; i < newcomers.length; i++) {
            secondRound[i + 1] = newcomers[i];
        }
        playRound(secondRound, 0, subscriptionId);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Enters `players`, triggers upkeep through the script and has the mock pick `players[winnerIndex]`.
    function playRound(address[] memory players, uint256 winnerIndex, uint256 subscriptionId)
        private
        returns (address winner)
    {
        for (uint256 i = 0; i < players.length; i++) {
            vm.prank(players[i]);
            raffle.enterRaffle{value: entranceFee}();
        }
        uint256 prize = entranceFee * players.length;
        assertEq(address(raffle).balance, prize);
        assertEq(raffle.getPlayers().length, players.length);

        // Upkeep isn't due until the interval has passed.
        performUpkeep.run(address(raffle));
        assertEq(uint256(raffle.getRaffleState()), uint256(Raffle.RaffleState.OPEN));

        vm.warp(vm.getBlockTimestamp() + interval + 1);
        vm.roll(vm.getBlockNumber() + 1);
        uint256 requestId = performUpkeepAndGetRequestId();
        assertEq(uint256(raffle.getRaffleState()), uint256(Raffle.RaffleState.CALCULATING));

        winner = players[winnerIndex];
        uint256 winnerStartingBalance = winner.balance;
        (uint96 subscriptionBalanceBefore,,,,) = vrfCoordinator.getSubscription(subscriptionId);

        // A word larger than the player count, so the winner is picked through the modulo.
        uint256[] memory randomWords = new uint256[](1);
        randomWords[0] = players.length * 1000 + winnerIndex;
        vm.expectEmit(true, false, false, false, address(raffle));
        emit Raffle.WinnerPicked(winner);
        vrfCoordinator.fulfillRandomWordsWithOverride(requestId, address(raffle), randomWords);

        // The mock swallows reverts from the raffle, so these checks are what prove the callback succeeded.
        assertEq(winner.balance, winnerStartingBalance + prize);
        assertEq(address(raffle).balance, 0);
        assertEq(raffle.getPlayers().length, 0);
        assertEq(uint256(raffle.getRaffleState()), uint256(Raffle.RaffleState.OPEN));
        assertEq(raffle.getLastTimeStamp(), vm.getBlockTimestamp());

        (uint96 subscriptionBalanceAfter,,,,) = vrfCoordinator.getSubscription(subscriptionId);
        assertLt(subscriptionBalanceAfter, subscriptionBalanceBefore);
    }

    function newPlayers(string memory round, uint256 count) private returns (address[] memory players) {
        players = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            players[i] = makeAddr(string.concat(round, "Player", vm.toString(i)));
            vm.deal(players[i], STARTING_PLAYER_BALANCE);
        }
    }

    /// @dev Runs the upkeep script and returns the request ID from the Raffle's `RequestedRaffleWinner` event.
    function performUpkeepAndGetRequestId() private returns (uint256) {
        vm.recordLogs();
        performUpkeep.run(address(raffle));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(raffle) && logs[i].topics[0] == Raffle.RequestedRaffleWinner.selector) {
                return uint256(logs[i].topics[1]);
            }
        }
        revert("RequestedRaffleWinner not emitted");
    }
}
