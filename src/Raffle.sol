// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {
    AutomationCompatibleInterface
} from "@chainlink/contracts/src/v0.8/automation/interfaces/AutomationCompatibleInterface.sol";

/**
 * @title Raffle
 * @author SonicWizard
 * @notice This contract manages a raffle where players can enter and a winner is selected.
 * @dev Picking a winner is triggered through `performUpkeep`, which anyone may call once `checkUpkeep` passes
 * (e.g. a Chainlink CRE workflow, a script, or `cast send`).
 */
contract Raffle is VRFConsumerBaseV2Plus, AutomationCompatibleInterface {
    enum RaffleState {
        OPEN,
        CALCULATING
    }

    uint16 private constant REQUEST_CONFIRMATIONS = 3;
    uint32 private constant NUM_WORDS = 1;

    uint256 private immutable i_entranceFee;
    uint256 private immutable i_interval;
    bytes32 private immutable i_keyHash;
    uint256 private immutable i_subscriptionId;
    uint32 private immutable i_callbackGasLimit;
    uint256 private s_lastTimeStamp;
    address payable[] private s_players;
    RaffleState private s_raffleState;

    event RaffleEntered(address indexed player);
    event WinnerPicked(address indexed winner);
    event RequestedRaffleWinner(uint256 indexed requestId);

    error Raffle__NotEnoughEth();
    error Raffle__TransferFailed();
    error Raffle__RaffleNotOpen();
    error Raffle__UpkeepNotNeeded(uint256 balance, uint256 playersLength, RaffleState raffleState);

    /**
     * @param entranceFee The fee required to enter the raffle, in wei.
     * @param interval The minimum time between winner picks, in seconds.
     * @param vrfCoordinator The address of the Chainlink VRF coordinator.
     * @param gasLane VRF gas lane key hash.
     * @param subscriptionId The Chainlink VRF subscription ID that funds requests.
     * @param callbackGasLimit The gas limit for the VRF callback.
     */
    constructor(
        uint256 entranceFee,
        uint256 interval,
        address vrfCoordinator,
        bytes32 gasLane,
        uint256 subscriptionId,
        uint32 callbackGasLimit
    ) VRFConsumerBaseV2Plus(vrfCoordinator) {
        i_entranceFee = entranceFee;
        i_interval = interval;
        i_keyHash = gasLane;
        i_subscriptionId = subscriptionId;
        i_callbackGasLimit = callbackGasLimit;
        s_lastTimeStamp = block.timestamp;
        s_raffleState = RaffleState.OPEN;
    }

    /**
     * @notice Enters the caller into the raffle.
     */
    function enterRaffle() external payable {
        require(msg.value >= i_entranceFee, Raffle__NotEnoughEth());
        require(s_raffleState == RaffleState.OPEN, Raffle__RaffleNotOpen());
        s_players.push(payable(msg.sender));
        emit RaffleEntered(msg.sender);
    }

    /**
     * @notice Requests randomness from Chainlink VRF to pick a winner from the current players.
     * @dev Callable by anyone, so it re-validates `checkUpkeep` and reverts if no upkeep is needed.
     * The winner is chosen and paid later, when the coordinator calls `fulfillRandomWords`.
     */
    function performUpkeep(
        bytes calldata /* performData */
    )
        external
    {
        (bool upkeepNeeded,) = checkUpkeep("");
        require(upkeepNeeded, Raffle__UpkeepNotNeeded(address(this).balance, s_players.length, s_raffleState));
        s_lastTimeStamp = block.timestamp;
        s_raffleState = RaffleState.CALCULATING;

        uint256 requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: i_keyHash,
                subId: i_subscriptionId,
                requestConfirmations: REQUEST_CONFIRMATIONS,
                callbackGasLimit: i_callbackGasLimit,
                numWords: NUM_WORDS,
                extraArgs: VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: false}))
            })
        );
        // requestId is only known after the call; the coordinator is trusted and the state is already CALCULATING.
        // forge-lint: disable-next-line(reentrancy-events)
        emit RequestedRaffleWinner(requestId);
    }

    /**
     * @notice Returns the fee required to enter the raffle.
     * @return The entrance fee, in wei.
     */
    function getEntranceFee() external view returns (uint256) {
        return i_entranceFee;
    }

    /**
     * @notice Returns when the current round started.
     * @return The timestamp of the last winner pick or upkeep, in seconds.
     */
    function getLastTimeStamp() external view returns (uint256) {
        return s_lastTimeStamp;
    }

    /**
     * @notice Returns the current state of the raffle.
     * @return Whether the raffle is open or calculating a winner.
     */
    function getRaffleState() external view returns (RaffleState) {
        return s_raffleState;
    }

    /**
     * @notice Checks whether it is time to pick a winner.
     * @dev Upkeep is needed when all of the following are true:
     * 1. The raffle is open.
     * 2. At least `i_interval` seconds have passed since the last winner pick.
     * 3. The raffle has at least one player.
     * 4. The contract holds ETH.
     * The VRF subscription must also be funded for the request to succeed.
     * @return upkeepNeeded True if `performUpkeep` should be called.
     * @return performData Unused; always empty.
     */
    function checkUpkeep(
        bytes memory /* checkData */
    )
        public
        view
        returns (
            bool upkeepNeeded,
            bytes memory /* performData */
        )
    {
        bool isOpen = s_raffleState == RaffleState.OPEN;
        bool timeHasPassed = block.timestamp - s_lastTimeStamp >= i_interval;
        bool hasPlayers = s_players.length > 0;
        bool hasBalance = address(this).balance > 0;
        upkeepNeeded = isOpen && timeHasPassed && hasPlayers && hasBalance;
        return (upkeepNeeded, "");
    }

    /**
     * @notice Returns all players currently entered in the raffle.
     * @return The list of player addresses.
     */
    function getPlayers() public view returns (address payable[] memory) {
        return s_players;
    }

    function fulfillRandomWords(uint256, uint256[] calldata randomWords) internal override {
        uint256 winnerIndex = randomWords[0] % s_players.length;
        address payable winner = s_players[winnerIndex];

        s_players = new address payable[](0);
        s_lastTimeStamp = block.timestamp;
        s_raffleState = RaffleState.OPEN;

        emit WinnerPicked(winner);

        (bool success,) = winner.call{value: address(this).balance}("");
        require(success, Raffle__TransferFailed());
    }
}
