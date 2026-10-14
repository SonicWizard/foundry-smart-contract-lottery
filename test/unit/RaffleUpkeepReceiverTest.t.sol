// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {
    IERC165
} from "@chainlink/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/utils/introspection/IERC165.sol";
import {DeployRaffle} from "../../script/DeployRaffle.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {DeployUpkeepReceiver} from "../../script/UpkeepReceiver.s.sol";
import {IReceiver} from "../../src/interfaces/IReceiver.sol";
import {Raffle} from "../../src/Raffle.sol";
import {RaffleUpkeepReceiver} from "../../src/RaffleUpkeepReceiver.sol";
import {SkipForkTest} from "../utils/SkipForkTest.sol";

contract RaffleUpkeepReceiverTest is SkipForkTest {
    bytes32 private constant WORKFLOW_ID = keccak256("raffle-upkeep");

    Raffle private raffle;
    RaffleUpkeepReceiver private receiver;
    address private forwarder;
    address private owner;
    bytes private report;
    address private player = makeAddr("player");

    /// @dev Enters `player` and moves time past the interval, so upkeep is needed.
    modifier upkeepNeeded() {
        hoax(player, raffle.getEntranceFee());
        raffle.enterRaffle{value: raffle.getEntranceFee()}();
        vm.warp(vm.getBlockTimestamp() + 31);
        vm.roll(vm.getBlockNumber() + 1);
        _;
    }

    function setUp() external {
        HelperConfig helperConfig;
        (raffle, helperConfig) = new DeployRaffle().run();
        HelperConfig.NetworkConfig memory config = helperConfig.getConfig();
        receiver = new DeployUpkeepReceiver().run(address(raffle), false);
        forwarder = config.creForwarder;
        owner = config.account;
        report = abi.encode(address(raffle));
    }

    /*//////////////////////////////////////////////////////////////
                               DEPLOYMENT
    //////////////////////////////////////////////////////////////*/

    function test_ConstructorStoresRaffleForwarderAndOwner() external view {
        assertEq(receiver.getRaffle(), address(raffle));
        assertEq(receiver.getForwarder(), forwarder);
        assertEq(receiver.owner(), owner);
        assertEq(receiver.getExpectedWorkflowId(), bytes32(0));
    }

    function test_RevertWhen_ConstructedWithZeroAddress() external {
        vm.expectRevert(RaffleUpkeepReceiver.RaffleUpkeepReceiver__ZeroAddress.selector);
        new RaffleUpkeepReceiver(address(0), forwarder);

        vm.expectRevert(RaffleUpkeepReceiver.RaffleUpkeepReceiver__ZeroAddress.selector);
        new RaffleUpkeepReceiver(address(raffle), address(0));
    }

    function test_SupportsReceiverInterfaces() external view {
        assertTrue(receiver.supportsInterface(type(IReceiver).interfaceId));
        assertTrue(receiver.supportsInterface(type(IERC165).interfaceId));
        assertFalse(receiver.supportsInterface(0xffffffff));
    }

    /*//////////////////////////////////////////////////////////////
                                ON REPORT
    //////////////////////////////////////////////////////////////*/

    function test_OnReportPerformsUpkeepWhenNeeded() external upkeepNeeded {
        vm.expectEmit(address(receiver));
        emit RaffleUpkeepReceiver.UpkeepPerformed();

        vm.prank(forwarder);
        receiver.onReport("", report);

        assertEq(uint256(raffle.getRaffleState()), uint256(Raffle.RaffleState.CALCULATING));
    }

    function test_OnReportSkipsWhenUpkeepNotNeeded() external {
        vm.expectEmit(address(receiver));
        emit RaffleUpkeepReceiver.UpkeepSkipped();

        vm.prank(forwarder);
        receiver.onReport("", report);

        assertEq(uint256(raffle.getRaffleState()), uint256(Raffle.RaffleState.OPEN));
    }

    function test_OnReportSkipsDuplicateReport() external upkeepNeeded {
        vm.startPrank(forwarder);
        receiver.onReport("", report);

        // A second report for the same round, such as one read from an older finalized block, is skipped.
        vm.expectEmit(address(receiver));
        emit RaffleUpkeepReceiver.UpkeepSkipped();
        receiver.onReport("", report);
        vm.stopPrank();
    }

    function testFuzz_RevertWhen_SenderIsNotForwarder(address sender) external upkeepNeeded {
        vm.assume(sender != forwarder);

        vm.prank(sender);
        vm.expectRevert(
            abi.encodeWithSelector(RaffleUpkeepReceiver.RaffleUpkeepReceiver__InvalidSender.selector, sender, forwarder)
        );
        receiver.onReport("", report);
    }

    function testFuzz_RevertWhen_ReportNamesAnotherRaffle(address otherRaffle) external upkeepNeeded {
        vm.assume(otherRaffle != address(raffle));

        vm.prank(forwarder);
        vm.expectRevert(
            abi.encodeWithSelector(
                RaffleUpkeepReceiver.RaffleUpkeepReceiver__WrongRaffle.selector, otherRaffle, address(raffle)
            )
        );
        receiver.onReport("", abi.encode(otherRaffle));
    }

    function test_OnReportAcceptsExpectedWorkflowId() external upkeepNeeded {
        vm.prank(owner);
        receiver.setExpectedWorkflowId(WORKFLOW_ID);

        vm.prank(forwarder);
        receiver.onReport(workflowMetadata(WORKFLOW_ID), report);

        assertEq(uint256(raffle.getRaffleState()), uint256(Raffle.RaffleState.CALCULATING));
    }

    function test_RevertWhen_WorkflowIdDoesNotMatch() external upkeepNeeded {
        vm.prank(owner);
        receiver.setExpectedWorkflowId(WORKFLOW_ID);
        bytes32 otherWorkflowId = keccak256("other-workflow");

        vm.prank(forwarder);
        vm.expectRevert(
            abi.encodeWithSelector(
                RaffleUpkeepReceiver.RaffleUpkeepReceiver__InvalidWorkflowId.selector, otherWorkflowId, WORKFLOW_ID
            )
        );
        receiver.onReport(workflowMetadata(otherWorkflowId), report);
    }

    function test_RevertWhen_WorkflowIdExpectedButMetadataMissing() external upkeepNeeded {
        vm.prank(owner);
        receiver.setExpectedWorkflowId(WORKFLOW_ID);

        // The simulation forwarder sends no workflow ID, so pinning one rejects simulated reports.
        vm.prank(forwarder);
        vm.expectRevert(
            abi.encodeWithSelector(
                RaffleUpkeepReceiver.RaffleUpkeepReceiver__InvalidWorkflowId.selector, bytes32(0), WORKFLOW_ID
            )
        );
        receiver.onReport("", report);
    }

    /*//////////////////////////////////////////////////////////////
                              OWNER SETTERS
    //////////////////////////////////////////////////////////////*/

    function test_SetForwarderChangesWhoCanReport() external upkeepNeeded {
        address newForwarder = makeAddr("newForwarder");
        vm.expectEmit(address(receiver));
        emit RaffleUpkeepReceiver.ForwarderUpdated(forwarder, newForwarder);
        vm.prank(owner);
        receiver.setForwarder(newForwarder);

        vm.prank(forwarder);
        vm.expectRevert(
            abi.encodeWithSelector(
                RaffleUpkeepReceiver.RaffleUpkeepReceiver__InvalidSender.selector, forwarder, newForwarder
            )
        );
        receiver.onReport("", report);

        vm.prank(newForwarder);
        receiver.onReport("", report);
        assertEq(uint256(raffle.getRaffleState()), uint256(Raffle.RaffleState.CALCULATING));
    }

    function test_SetExpectedWorkflowIdEmitsEvent() external {
        vm.expectEmit(address(receiver));
        emit RaffleUpkeepReceiver.ExpectedWorkflowIdUpdated(bytes32(0), WORKFLOW_ID);
        vm.prank(owner);
        receiver.setExpectedWorkflowId(WORKFLOW_ID);

        assertEq(receiver.getExpectedWorkflowId(), WORKFLOW_ID);
    }

    function test_RevertWhen_SettingZeroForwarder() external {
        vm.prank(owner);
        vm.expectRevert(RaffleUpkeepReceiver.RaffleUpkeepReceiver__ZeroAddress.selector);
        receiver.setForwarder(address(0));
    }

    function test_RevertWhen_NonOwnerCallsSetters() external {
        vm.startPrank(player);
        vm.expectRevert("Only callable by owner");
        receiver.setForwarder(player);
        vm.expectRevert("Only callable by owner");
        receiver.setExpectedWorkflowId(WORKFLOW_ID);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Builds forwarder metadata: workflow ID, 10-byte name, owner and 2-byte report ID, packed.
    function workflowMetadata(bytes32 workflowId) private view returns (bytes memory) {
        return abi.encodePacked(workflowId, bytes10("raffle"), owner, bytes2(0x0001));
    }
}
