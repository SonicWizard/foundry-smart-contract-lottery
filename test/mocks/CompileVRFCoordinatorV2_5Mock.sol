// SPDX-License-Identifier: MIT
// Chainlink pins the VRF mock to solc 0.8.19, so ^0.8.27 code can't import it. This file only exists to get it
// compiled; scripts and tests deploy it by artifact name and call it through `IVRFCoordinatorV2_5Mock`.
pragma solidity 0.8.19;

// forge-lint: disable-next-line(unused-import)
import {VRFCoordinatorV2_5Mock} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";
