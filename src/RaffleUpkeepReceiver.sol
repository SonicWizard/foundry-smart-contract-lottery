// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ConfirmedOwner} from "@chainlink/contracts/src/v0.8/shared/access/ConfirmedOwner.sol";
import {
    IERC165
} from "@chainlink/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/utils/introspection/IERC165.sol";
import {IReceiver} from "./interfaces/IReceiver.sol";
import {Raffle} from "./Raffle.sol";

/**
 * @title RaffleUpkeepReceiver
 * @author SonicWizard
 * @notice Lets a Chainlink CRE workflow trigger `performUpkeep` on one Raffle, in place of Chainlink Automation.
 * @dev The workflow reads `checkUpkeep` off-chain on a cron schedule and, when upkeep is needed, sends a signed report
 * through the CRE forwarder. Only that forwarder may call `onReport`, and the owner can also pin a workflow ID.
 * CRE reads at the last finalized block (about 13 minutes behind the head on Sepolia), so a report can arrive after
 * the round has already moved on; `onReport` re-checks `checkUpkeep` and skips such reports instead of reverting.
 */
contract RaffleUpkeepReceiver is IReceiver, ConfirmedOwner {
    Raffle private immutable i_raffle;
    address private s_forwarder;
    bytes32 private s_expectedWorkflowId;

    event UpkeepPerformed();
    event UpkeepSkipped();
    event ForwarderUpdated(address indexed previousForwarder, address indexed newForwarder);
    event ExpectedWorkflowIdUpdated(bytes32 indexed previousWorkflowId, bytes32 indexed newWorkflowId);

    error RaffleUpkeepReceiver__ZeroAddress();
    error RaffleUpkeepReceiver__InvalidSender(address sender, address expected);
    error RaffleUpkeepReceiver__InvalidWorkflowId(bytes32 received, bytes32 expected);
    error RaffleUpkeepReceiver__WrongRaffle(address received, address expected);

    /**
     * @param raffle The Raffle this receiver triggers.
     * @param forwarder The CRE forwarder allowed to deliver reports.
     */
    constructor(address raffle, address forwarder) ConfirmedOwner(msg.sender) {
        require(raffle != address(0) && forwarder != address(0), RaffleUpkeepReceiver__ZeroAddress());
        i_raffle = Raffle(raffle);
        s_forwarder = forwarder;
        emit ForwarderUpdated(address(0), forwarder);
    }

    /**
     * @notice Handles a report from the CRE workflow by performing upkeep if it is still needed.
     * @param metadata Workflow ID (first 32 bytes), name and owner, packed by the forwarder.
     * @param report `abi.encode(raffle)`, naming the Raffle the workflow checked.
     */
    function onReport(bytes calldata metadata, bytes calldata report) external {
        require(msg.sender == s_forwarder, RaffleUpkeepReceiver__InvalidSender(msg.sender, s_forwarder));
        if (s_expectedWorkflowId != bytes32(0)) {
            bytes32 workflowId = metadata.length >= 32 ? bytes32(metadata[:32]) : bytes32(0);
            require(
                workflowId == s_expectedWorkflowId,
                RaffleUpkeepReceiver__InvalidWorkflowId(workflowId, s_expectedWorkflowId)
            );
        }
        address raffle = abi.decode(report, (address));
        require(raffle == address(i_raffle), RaffleUpkeepReceiver__WrongRaffle(raffle, address(i_raffle)));

        // performData is always empty for this Raffle.
        // forge-lint: disable-next-line(unused-return)
        (bool upkeepNeeded,) = i_raffle.checkUpkeep("");
        if (!upkeepNeeded) {
            emit UpkeepSkipped();
            return;
        }
        // Emitted first so no log follows the external call; if performUpkeep reverts, so does the event.
        emit UpkeepPerformed();
        i_raffle.performUpkeep("");
    }

    /**
     * @notice Changes the forwarder allowed to deliver reports, such as from the simulation forwarder to the
     * production one.
     * @param forwarder The new forwarder; must not be the zero address.
     */
    function setForwarder(address forwarder) external onlyOwner {
        require(forwarder != address(0), RaffleUpkeepReceiver__ZeroAddress());
        address previousForwarder = s_forwarder;
        s_forwarder = forwarder;
        emit ForwarderUpdated(previousForwarder, forwarder);
    }

    /**
     * @notice Restricts reports to one deployed workflow. Leave unset while simulating, as the simulation forwarder
     * sends no workflow ID.
     * @param workflowId The workflow ID to accept, or zero to accept any workflow.
     */
    function setExpectedWorkflowId(bytes32 workflowId) external onlyOwner {
        bytes32 previousWorkflowId = s_expectedWorkflowId;
        s_expectedWorkflowId = workflowId;
        emit ExpectedWorkflowIdUpdated(previousWorkflowId, workflowId);
    }

    /**
     * @notice Returns the Raffle this receiver triggers.
     * @return The Raffle's address.
     */
    function getRaffle() external view returns (address) {
        return address(i_raffle);
    }

    /**
     * @notice Returns the forwarder allowed to deliver reports.
     * @return The forwarder's address.
     */
    function getForwarder() external view returns (address) {
        return s_forwarder;
    }

    /**
     * @notice Returns the workflow ID reports must come from.
     * @return The workflow ID, or zero if any workflow is accepted.
     */
    function getExpectedWorkflowId() external view returns (bytes32) {
        return s_expectedWorkflowId;
    }

    /**
     * @notice Reports support for `IReceiver`, which the forwarder checks before delivering.
     * @param interfaceId The ERC-165 interface ID to check.
     * @return True for `IReceiver` and `IERC165`.
     */
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IReceiver).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
