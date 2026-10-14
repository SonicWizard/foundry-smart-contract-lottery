// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {RaffleUpkeepReceiver} from "../src/RaffleUpkeepReceiver.sol";

/**
 * @title DeployUpkeepReceiver
 * @author SonicWizard
 * @notice Deploys a RaffleUpkeepReceiver that lets a CRE workflow trigger upkeep on an existing Raffle.
 * @dev Pass `simulation = true` to accept reports from `cre workflow simulate --broadcast`, or false for a deployed
 * workflow. `SetUpkeepForwarder` switches between them later. Usage:
 * forge script script/UpkeepReceiver.s.sol:DeployUpkeepReceiver --sig "run(address,bool)" <raffle> <simulation>
 * --rpc-url <url> --account <acct> --broadcast
 */
contract DeployUpkeepReceiver is Script {
    /**
     * @notice Deploys a receiver for `raffle` with the current chain's configured account and forwarder.
     * @param raffle The deployed Raffle to trigger.
     * @param simulation True to use the simulation forwarder, false for the production one.
     * @return receiver The deployed receiver.
     */
    function run(address raffle, bool simulation) external returns (RaffleUpkeepReceiver receiver) {
        HelperConfig.NetworkConfig memory config = new HelperConfig().getConfig();
        address forwarder = simulation ? config.creSimulationForwarder : config.creForwarder;
        return deployUpkeepReceiver(raffle, forwarder, config.account);
    }

    /**
     * @notice Deploys a receiver for `raffle` that accepts reports from `forwarder`, owned by `account`.
     * @param raffle The deployed Raffle to trigger.
     * @param forwarder The CRE forwarder allowed to deliver reports.
     * @param account The account that broadcasts and will own the receiver.
     * @return receiver The deployed receiver.
     */
    function deployUpkeepReceiver(address raffle, address forwarder, address account)
        public
        returns (RaffleUpkeepReceiver receiver)
    {
        vm.startBroadcast(account);
        receiver = new RaffleUpkeepReceiver(raffle, forwarder);
        vm.stopBroadcast();
        console.log("Deployed RaffleUpkeepReceiver", address(receiver), "with forwarder", forwarder);
    }
}

/**
 * @title SetUpkeepForwarder
 * @author SonicWizard
 * @notice Switches a RaffleUpkeepReceiver between the simulation and production CRE forwarders.
 * @dev Only the receiver's owner can do this, so broadcast from the configured account. Usage:
 * forge script script/UpkeepReceiver.s.sol:SetUpkeepForwarder --sig "run(address,bool)" <receiver> <simulation>
 * --rpc-url <url> --account <acct> --broadcast
 */
contract SetUpkeepForwarder is Script {
    /**
     * @notice Points `receiver` at the current chain's simulation or production forwarder.
     * @param receiver The RaffleUpkeepReceiver to update.
     * @param simulation True to use the simulation forwarder, false for the production one.
     */
    function run(address receiver, bool simulation) external {
        HelperConfig.NetworkConfig memory config = new HelperConfig().getConfig();
        address forwarder = simulation ? config.creSimulationForwarder : config.creForwarder;
        setUpkeepForwarder(receiver, forwarder, config.account);
    }

    /**
     * @notice Points `receiver` at `forwarder`.
     * @param receiver The RaffleUpkeepReceiver to update.
     * @param forwarder The CRE forwarder to accept reports from.
     * @param account The account that broadcasts; it must own the receiver.
     */
    function setUpkeepForwarder(address receiver, address forwarder, address account) public {
        vm.startBroadcast(account);
        RaffleUpkeepReceiver(receiver).setForwarder(forwarder);
        vm.stopBroadcast();
        console.log("Receiver", receiver, "now accepts reports from", forwarder);
    }
}
