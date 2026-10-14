// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {CodeConstants} from "../../script/HelperConfig.s.sol";

/**
 * @title SkipForkTest
 * @notice Base for test suites that run both locally and against a Sepolia fork.
 */
abstract contract SkipForkTest is CodeConstants, Test {
    /// @dev For tests that need the local VRF mock; on a fork the real coordinator would fulfill. Forge reports
    /// these as skipped rather than passed. List it before other modifiers so their setup doesn't run either.
    modifier skipFork() {
        vm.skip(block.chainid != LOCAL_CHAIN_ID);
        _;
    }
}
