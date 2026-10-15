// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Vm} from "forge-std/Vm.sol";
import {DeployRaffle} from "../../script/DeployRaffle.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {Raffle} from "../../src/Raffle.sol";
import {EthRejecter} from "../mocks/EthRejecter.sol";
import {IVRFCoordinatorV2_5Mock} from "../mocks/IVRFCoordinatorV2_5Mock.sol";
import {SkipForkTest} from "../utils/SkipForkTest.sol";

contract RaffleTest is SkipForkTest {
    uint256 private constant STARTING_PLAYER_BALANCE = 10 ether;
    uint256 private constant ADDITIONAL_PLAYERS = 3;
    /// @dev Enough players that clearing them one slot at a time would exceed the 500k callback gas limit on Sepolia.
    uint256 private constant MANY_PLAYERS = 50;

    Raffle private raffle;
    uint256 private entranceFee;
    uint256 private interval;
    address private vrfCoordinator;
    address private player = makeAddr("player");

    /// @dev Enters `player` and moves time past the interval, so upkeep is needed.
    modifier raffleEntered() {
        vm.prank(player);
        raffle.enterRaffle{value: entranceFee}();
        vm.warp(vm.getBlockTimestamp() + interval + 1);
        vm.roll(vm.getBlockNumber() + 1);
        _;
    }

    function setUp() external {
        DeployRaffle deployer = new DeployRaffle();
        HelperConfig helperConfig;
        (raffle, helperConfig) = deployer.run();

        HelperConfig.NetworkConfig memory config = helperConfig.getConfig();
        entranceFee = config.entranceFee;
        interval = config.interval;
        vrfCoordinator = config.vrfCoordinator;

        vm.deal(player, STARTING_PLAYER_BALANCE);
    }

    /*//////////////////////////////////////////////////////////////
                              INITIAL STATE
    //////////////////////////////////////////////////////////////*/

    function test_RaffleInitializesOpen() external view {
        assertEq(uint256(raffle.getRaffleState()), uint256(Raffle.RaffleState.OPEN));
        assertEq(raffle.getEntranceFee(), entranceFee);
        assertEq(raffle.getPlayers().length, 0);
    }

    /*//////////////////////////////////////////////////////////////
                              ENTER RAFFLE
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_EntranceFeeTooLow() external {
        vm.prank(player);
        vm.expectRevert(Raffle.Raffle__NotEnoughEth.selector);
        raffle.enterRaffle{value: entranceFee - 1}();
    }

    function test_EnterRaffleRecordsPlayer() external {
        vm.prank(player);
        raffle.enterRaffle{value: entranceFee}();

        address payable[] memory players = raffle.getPlayers();
        assertEq(players.length, 1);
        assertEq(players[0], player);
        assertEq(raffle.getPrizePool(), entranceFee);
        assertEq(address(raffle).balance, entranceFee);
    }

    function test_EnterRaffleEmitsEvent() external {
        vm.expectEmit(true, false, false, false, address(raffle));
        emit Raffle.RaffleEntered(player);

        vm.prank(player);
        raffle.enterRaffle{value: entranceFee}();
    }

    function test_RevertWhen_EnteringWhileCalculating() external raffleEntered {
        raffle.performUpkeep("");

        vm.prank(player);
        vm.expectRevert(Raffle.Raffle__RaffleNotOpen.selector);
        raffle.enterRaffle{value: entranceFee}();
    }

    /*//////////////////////////////////////////////////////////////
                              CHECK UPKEEP
    //////////////////////////////////////////////////////////////*/

    function test_CheckUpkeepFalseWithoutPlayersOrBalance() external {
        vm.warp(vm.getBlockTimestamp() + interval + 1);
        vm.roll(vm.getBlockNumber() + 1);

        (bool upkeepNeeded,) = raffle.checkUpkeep("");
        assertFalse(upkeepNeeded);
    }

    function test_CheckUpkeepFalseWhenRaffleNotOpen() external raffleEntered {
        raffle.performUpkeep("");

        (bool upkeepNeeded,) = raffle.checkUpkeep("");
        assertFalse(upkeepNeeded);
    }

    function test_CheckUpkeepFalseBeforeIntervalPasses() external {
        vm.prank(player);
        raffle.enterRaffle{value: entranceFee}();
        vm.warp(vm.getBlockTimestamp() + interval - 1);

        (bool upkeepNeeded,) = raffle.checkUpkeep("");
        assertFalse(upkeepNeeded);
    }

    function test_CheckUpkeepTrueWhenAllConditionsMet() external raffleEntered {
        (bool upkeepNeeded,) = raffle.checkUpkeep("");
        assertTrue(upkeepNeeded);
    }

    /*//////////////////////////////////////////////////////////////
                             PERFORM UPKEEP
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_PerformUpkeepNotNeeded() external {
        vm.prank(player);
        raffle.enterRaffle{value: entranceFee}();

        vm.expectRevert(
            abi.encodeWithSelector(Raffle.Raffle__UpkeepNotNeeded.selector, entranceFee, 1, Raffle.RaffleState.OPEN)
        );
        raffle.performUpkeep("");
    }

    function test_PerformUpkeepSetsCalculatingAndEmitsRequestId() external raffleEntered {
        uint256 requestId = performUpkeepAndGetRequestId();

        assertGt(requestId, 0);
        assertEq(uint256(raffle.getRaffleState()), uint256(Raffle.RaffleState.CALCULATING));
        assertEq(raffle.getLastTimeStamp(), vm.getBlockTimestamp());
    }

    /*//////////////////////////////////////////////////////////////
                          FULFILL RANDOM WORDS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_RevertWhen_FulfillCalledBeforePerformUpkeep(uint256 requestId) external skipFork raffleEntered {
        vm.expectRevert(IVRFCoordinatorV2_5Mock.InvalidRequest.selector);
        IVRFCoordinatorV2_5Mock(vrfCoordinator).fulfillRandomWords(requestId, address(raffle));
    }

    function testFuzz_FulfillPicksWinnerResetsAndCreditsPrize(uint256 randomWord) external skipFork raffleEntered {
        address[] memory players = new address[](ADDITIONAL_PLAYERS + 1);
        players[0] = player;
        for (uint256 i = 1; i <= ADDITIONAL_PLAYERS; i++) {
            players[i] = makeAddr(string.concat("player", vm.toString(i)));
            hoax(players[i], STARTING_PLAYER_BALANCE);
            raffle.enterRaffle{value: entranceFee}();
        }
        uint256 prize = entranceFee * players.length;
        address expectedWinner = players[randomWord % players.length];

        uint256 requestId = performUpkeepAndGetRequestId();
        // VRF answers a few blocks later, so fulfillment should move the timestamp forward again.
        vm.warp(vm.getBlockTimestamp() + 36);
        vm.roll(vm.getBlockNumber() + 3);

        uint256[] memory randomWords = new uint256[](1);
        randomWords[0] = randomWord;
        vm.expectEmit(true, false, false, false, address(raffle));
        emit Raffle.WinnerPicked(expectedWinner);
        IVRFCoordinatorV2_5Mock(vrfCoordinator).fulfillRandomWordsWithOverride(requestId, address(raffle), randomWords);

        // The prize is credited, not sent: it stays in the raffle until the winner withdraws it.
        assertEq(raffle.getWinnings(expectedWinner), prize);
        assertEq(expectedWinner.balance, STARTING_PLAYER_BALANCE - entranceFee);
        assertEq(address(raffle).balance, prize);
        assertEq(raffle.getPrizePool(), 0);
        assertEq(uint256(raffle.getRaffleState()), uint256(Raffle.RaffleState.OPEN));
        assertEq(raffle.getPlayers().length, 0);
        assertEq(raffle.getLastTimeStamp(), vm.getBlockTimestamp());
    }

    function test_WinnerThatRejectsEthDoesNotStopRaffle() external {
        address rejecter = address(new EthRejecter());
        hoax(rejecter, STARTING_PLAYER_BALANCE);
        raffle.enterRaffle{value: entranceFee}();
        vm.warp(vm.getBlockTimestamp() + interval + 1);
        vm.roll(vm.getBlockNumber() + 1);

        pickWinner(performUpkeepAndGetRequestId(), 0);

        assertEq(raffle.getWinnings(rejecter), entranceFee);
        assertEq(uint256(raffle.getRaffleState()), uint256(Raffle.RaffleState.OPEN));

        // The next round runs as normal.
        vm.prank(player);
        raffle.enterRaffle{value: entranceFee}();
        vm.warp(vm.getBlockTimestamp() + interval + 1);
        vm.roll(vm.getBlockNumber() + 1);
        pickWinner(performUpkeepAndGetRequestId(), 0);
        assertEq(raffle.getWinnings(player), entranceFee);
    }

    function test_CallbackGasDoesNotGrowWithPlayers() external {
        uint256 gasWithOnePlayer = enterPlayersAndMeasureCallbackGas(1, "few");
        uint256 gasWithManyPlayers = enterPlayersAndMeasureCallbackGas(MANY_PLAYERS, "many");
        // The request IDs differ, which shifts the cost by a few gas; clearing even one slot would cost thousands.
        assertApproxEqAbs(gasWithManyPlayers, gasWithOnePlayer, 100);
    }

    function test_NewRoundOnlyIncludesItsOwnPlayers() external raffleEntered {
        for (uint256 i = 1; i <= ADDITIONAL_PLAYERS; i++) {
            hoax(makeAddr(string.concat("player", vm.toString(i))), STARTING_PLAYER_BALANCE);
            raffle.enterRaffle{value: entranceFee}();
        }
        pickWinner(performUpkeepAndGetRequestId(), 0);

        // The newcomer reuses the first slot; the slots left over from round one must not count as players.
        address newcomer = makeAddr("newcomer");
        hoax(newcomer, STARTING_PLAYER_BALANCE);
        raffle.enterRaffle{value: entranceFee}();
        address payable[] memory players = raffle.getPlayers();
        assertEq(players.length, 1);
        assertEq(players[0], newcomer);

        vm.warp(vm.getBlockTimestamp() + interval + 1);
        vm.roll(vm.getBlockNumber() + 1);
        pickWinner(performUpkeepAndGetRequestId(), ADDITIONAL_PLAYERS);
        assertEq(raffle.getWinnings(newcomer), entranceFee);
    }

    /*//////////////////////////////////////////////////////////////
                           WITHDRAW WINNINGS
    //////////////////////////////////////////////////////////////*/

    function test_WithdrawWinningsPaysWinner() external raffleEntered {
        pickWinner(performUpkeepAndGetRequestId(), 0);
        uint256 balanceBefore = player.balance;

        vm.expectEmit(true, false, false, true, address(raffle));
        emit Raffle.WinningsWithdrawn(player, entranceFee);
        vm.prank(player);
        raffle.withdrawWinnings();

        assertEq(player.balance, balanceBefore + entranceFee);
        assertEq(raffle.getWinnings(player), 0);
        assertEq(address(raffle).balance, 0);
    }

    function test_WinningsAccumulateAcrossRounds() external raffleEntered {
        pickWinner(performUpkeepAndGetRequestId(), 0);

        // Unclaimed winnings stay out of the next round's prize pool.
        vm.prank(player);
        raffle.enterRaffle{value: entranceFee}();
        assertEq(raffle.getPrizePool(), entranceFee);
        vm.warp(vm.getBlockTimestamp() + interval + 1);
        vm.roll(vm.getBlockNumber() + 1);
        pickWinner(performUpkeepAndGetRequestId(), 0);

        assertEq(raffle.getWinnings(player), 2 * entranceFee);
        vm.prank(player);
        raffle.withdrawWinnings();
        assertEq(address(raffle).balance, 0);
    }

    function test_RevertWhen_WithdrawingWithoutWinnings() external {
        vm.prank(player);
        vm.expectRevert(Raffle.Raffle__NoWinnings.selector);
        raffle.withdrawWinnings();
    }

    function test_RevertWhen_WithdrawalRejected() external {
        address rejecter = address(new EthRejecter());
        hoax(rejecter, STARTING_PLAYER_BALANCE);
        raffle.enterRaffle{value: entranceFee}();
        vm.warp(vm.getBlockTimestamp() + interval + 1);
        vm.roll(vm.getBlockNumber() + 1);
        pickWinner(performUpkeepAndGetRequestId(), 0);

        // A failed payment reverts, so the winnings are kept.
        vm.prank(rejecter);
        vm.expectRevert(Raffle.Raffle__TransferFailed.selector);
        raffle.withdrawWinnings();
        assertEq(raffle.getWinnings(rejecter), entranceFee);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Calls `performUpkeep` and returns the request ID from the Raffle's `RequestedRaffleWinner` event.
    function performUpkeepAndGetRequestId() private returns (uint256) {
        vm.recordLogs();
        raffle.performUpkeep("");
        Vm.Log[] memory logs = vm.getRecordedLogs();

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(raffle) && logs[i].topics[0] == Raffle.RequestedRaffleWinner.selector) {
                return uint256(logs[i].topics[1]);
            }
        }
        revert("RequestedRaffleWinner not emitted");
    }

    /// @dev Enters `count` new players, starts a draw and returns the gas `fulfillRandomWords` uses, with the raffle's
    /// storage cold as it would be in the coordinator's transaction.
    function enterPlayersAndMeasureCallbackGas(uint256 count, string memory prefix) private returns (uint256) {
        for (uint256 i = 0; i < count; i++) {
            hoax(makeAddr(string.concat(prefix, vm.toString(i))), STARTING_PLAYER_BALANCE);
            raffle.enterRaffle{value: entranceFee}();
        }
        vm.warp(vm.getBlockTimestamp() + interval + 1);
        vm.roll(vm.getBlockNumber() + 1);
        uint256 requestId = performUpkeepAndGetRequestId();

        uint256[] memory randomWords = new uint256[](1);
        vm.cool(address(raffle));
        vm.prank(vrfCoordinator);
        uint256 gasBefore = gasleft();
        raffle.rawFulfillRandomWords(requestId, randomWords);
        return gasBefore - gasleft();
    }

    /// @dev Answers `requestId` as the coordinator. Unlike the local mock, which swallows the raffle's reverts, this
    /// surfaces them, and it also works on a fork.
    function pickWinner(uint256 requestId, uint256 randomWord) private {
        uint256[] memory randomWords = new uint256[](1);
        randomWords[0] = randomWord;
        vm.prank(vrfCoordinator);
        raffle.rawFulfillRandomWords(requestId, randomWords);
    }
}
