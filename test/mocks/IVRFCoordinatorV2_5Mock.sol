// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IVRFCoordinatorV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/interfaces/IVRFCoordinatorV2Plus.sol";

/**
 * @title IVRFCoordinatorV2_5Mock
 * @notice The parts of Chainlink's `VRFCoordinatorV2_5Mock` used by scripts and tests.
 */
interface IVRFCoordinatorV2_5Mock is IVRFCoordinatorV2Plus {
    error InvalidRequest();

    /**
     * @notice Adds `amount` LINK juels to a subscription without transferring any tokens.
     */
    function fundSubscription(uint256 subId, uint256 amount) external;

    /**
     * @notice Fulfills a request with random words derived from `requestId`.
     */
    function fulfillRandomWords(uint256 requestId, address consumer) external;

    /**
     * @notice Fulfills a request with caller-chosen random words.
     */
    function fulfillRandomWordsWithOverride(uint256 requestId, address consumer, uint256[] memory words) external;
}
