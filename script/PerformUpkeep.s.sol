// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";
import {Raffle} from "../src/Raffle.sol";

/**
 * @title PerformUpkeep
 * @author SonicWizard
 * @notice Manually triggers a raffle's `performUpkeep`; the fallback for the CRE workflow (see RaffleUpkeepReceiver).
 * @dev Usage: forge script script/PerformUpkeep.s.sol --sig "run(address)" <raffle> --rpc-url <url> --account <acct>
 * --broadcast
 */
contract PerformUpkeep is Script {
    /**
     * @notice Calls `performUpkeep` on `raffle` if `checkUpkeep` says it is needed.
     * @param raffle The address of the deployed Raffle contract.
     */
    function run(address raffle) external {
        (bool upkeepNeeded,) = Raffle(raffle).checkUpkeep("");
        if (!upkeepNeeded) {
            console.log("Upkeep not needed; skipping.");
            return;
        }

        vm.startBroadcast();
        Raffle(raffle).performUpkeep("");
        vm.stopBroadcast();
    }
}
