// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/**
 * @title EthRejecter
 * @notice A player with no `receive` or `fallback`, so any plain ETH transfer to it reverts.
 */
contract EthRejecter {}
