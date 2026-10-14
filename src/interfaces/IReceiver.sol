// SPDX-License-Identifier: MIT
// Copied from Chainlink's CRE contracts (chainlink-evm `contracts/cre/src/v1/interfaces/IReceiver.sol`, via
// github.com/smartcontractkit/cre-templates). The chainlink-brownie-contracts release in lib/ only has the older
// Keystone `onReport(bytes32, address, bytes)` signature, which CRE forwarders no longer call.
pragma solidity ^0.8.0;

import {
    IERC165
} from "@chainlink/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/utils/introspection/IERC165.sol";

/// @title IReceiver - receives keystone reports
/// @notice Implementations must support the IReceiver interface through ERC165.
interface IReceiver is IERC165 {
    /// @notice Handles incoming keystone reports.
    /// @dev If this function call reverts, it can be retried with a higher gas
    /// limit. The receiver is responsible for discarding stale reports.
    /// @param metadata Report's metadata.
    /// @param report Workflow report.
    function onReport(bytes calldata metadata, bytes calldata report) external;
}
