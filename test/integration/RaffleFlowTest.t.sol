// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Vm} from "forge-std/Vm.sol";
import {DeployRaffle} from "../../script/DeployRaffle.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {PerformUpkeep} from "../../script/PerformUpkeep.s.sol";
import {DeployUpkeepReceiver} from "../../script/UpkeepReceiver.s.sol";
import {Raffle} from "../../src/Raffle.sol";
import {RaffleUpkeepReceiver} from "../../src/RaffleUpkeepReceiver.sol";
import {IVRFCoordinatorV2_5Mock} from "../mocks/IVRFCoordinatorV2_5Mock.sol";
import {SkipForkTest} from "../utils/SkipForkTest.sol";

/// @dev Runs whole raffle rounds the way they happen in practice: deploy scripts, entries, upkeep (by the script or a
/// CRE report), VRF answer.
contract RaffleFlowTest is SkipForkTest {
    uint256 private constant STARTING_PLAYER_BALANCE = 10 ether;
    uint256 private constant FIRST_ROUND_PLAYERS = 4;
    uint256 private constant SECOND_ROUND_NEW_PLAYERS = 2;

    Raffle private raffle;
    PerformUpkeep private performUpkeep;
    RaffleUpkeepReceiver private receiver;
    address private creForwarder;
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
        receiver = new DeployUpkeepReceiver().run(address(raffle), false);
        creForwarder = config.creForwarder;
    }

    function test_RunsTwoRoundsWithMultiplePlayers() external skipFork {
        // DeployRaffle created the mock's only subscription, funded it and registered the raffle on it.
        uint256 subscriptionId = vrfCoordinator.getActiveSubscriptionIds(0, 1)[0];
        (uint96 subscriptionBalance,,,, address[] memory consumers) = vrfCoordinator.getSubscription(subscriptionId);
        assertEq(subscriptionBalance, LOCAL_SUBSCRIPTION_FUND_AMOUNT);
        assertEq(consumers.length, 1);
        assertEq(consumers[0], address(raffle));

        // Round one is triggered by the PerformUpkeep script, the manual fallback.
        address[] memory firstRound = newPlayers("first", FIRST_ROUND_PLAYERS);
        address firstWinner = playRound(firstRound, 2, subscriptionId, false);

        // Round two is triggered by a CRE report. The first winner plays again with new players without withdrawing,
        // and wins again: only this round's prize is added, so nothing from round one (players or ETH) may leak in.
        address[] memory newcomers = newPlayers("second", SECOND_ROUND_NEW_PLAYERS);
        address[] memory secondRound = new address[](SECOND_ROUND_NEW_PLAYERS + 1);
        secondRound[0] = firstWinner;
        for (uint256 i = 0; i < newcomers.length; i++) {
            secondRound[i + 1] = newcomers[i];
        }
        playRound(secondRound, 0, subscriptionId, true);

        uint256 totalWinnings = entranceFee * (FIRST_ROUND_PLAYERS + SECOND_ROUND_NEW_PLAYERS + 1);
        assertEq(raffle.getWinnings(firstWinner), totalWinnings);
        uint256 balanceBefore = firstWinner.balance;
        vm.prank(firstWinner);
        raffle.withdrawWinnings();
        assertEq(firstWinner.balance, balanceBefore + totalWinnings);
        assertEq(address(raffle).balance, 0);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Enters `players`, triggers upkeep (through the CRE receiver if `viaCre`, else the script) and has the mock
    /// pick `players[winnerIndex]`.
    function playRound(address[] memory players, uint256 winnerIndex, uint256 subscriptionId, bool viaCre)
        private
        returns (address winner)
    {
        for (uint256 i = 0; i < players.length; i++) {
            vm.prank(players[i]);
            raffle.enterRaffle{value: entranceFee}();
        }
        uint256 prize = entranceFee * players.length;
        assertEq(raffle.getPrizePool(), prize);
        assertEq(raffle.getPlayers().length, players.length);

        // Upkeep isn't due until the interval has passed, so an early trigger (or a stale CRE report) does nothing.
        triggerUpkeep(viaCre);
        assertEq(uint256(raffle.getRaffleState()), uint256(Raffle.RaffleState.OPEN));

        vm.warp(vm.getBlockTimestamp() + interval + 1);
        vm.roll(vm.getBlockNumber() + 1);
        uint256 requestId = performUpkeepAndGetRequestId(viaCre);
        assertEq(uint256(raffle.getRaffleState()), uint256(Raffle.RaffleState.CALCULATING));

        winner = players[winnerIndex];
        uint256 winningsBefore = raffle.getWinnings(winner);
        (uint96 subscriptionBalanceBefore,,,,) = vrfCoordinator.getSubscription(subscriptionId);

        // A word larger than the player count, so the winner is picked through the modulo.
        uint256[] memory randomWords = new uint256[](1);
        randomWords[0] = players.length * 1000 + winnerIndex;
        vm.expectEmit(true, false, false, false, address(raffle));
        emit Raffle.WinnerPicked(winner);
        vrfCoordinator.fulfillRandomWordsWithOverride(requestId, address(raffle), randomWords);

        // The mock swallows reverts from the raffle, so these checks are what prove the callback succeeded.
        assertEq(raffle.getWinnings(winner), winningsBefore + prize);
        assertEq(raffle.getPrizePool(), 0);
        // In these rounds the winner is the only one with unclaimed winnings.
        assertEq(address(raffle).balance, raffle.getWinnings(winner));
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

    /// @dev Delivers a CRE report to the receiver as the forwarder if `viaCre`, else runs the upkeep script.
    function triggerUpkeep(bool viaCre) private {
        if (viaCre) {
            vm.prank(creForwarder);
            receiver.onReport("", abi.encode(address(raffle)));
        } else {
            performUpkeep.run(address(raffle));
        }
    }

    /// @dev Triggers upkeep and returns the request ID from the Raffle's `RequestedRaffleWinner` event.
    function performUpkeepAndGetRequestId(bool viaCre) private returns (uint256) {
        vm.recordLogs();
        triggerUpkeep(viaCre);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(raffle) && logs[i].topics[0] == Raffle.RequestedRaffleWinner.selector) {
                return uint256(logs[i].topics[1]);
            }
        }
        revert("RequestedRaffleWinner not emitted");
    }
}
