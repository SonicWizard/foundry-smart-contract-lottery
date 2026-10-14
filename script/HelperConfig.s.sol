// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script} from "forge-std/Script.sol";
import {IVRFCoordinatorV2_5Mock} from "../test/mocks/IVRFCoordinatorV2_5Mock.sol";

/**
 * @title CodeConstants
 * @author SonicWizard
 * @notice Chain IDs and VRF mock values shared by scripts and tests.
 */
abstract contract CodeConstants {
    uint256 public constant ETH_SEPOLIA_CHAIN_ID = 11155111;
    uint256 public constant LOCAL_CHAIN_ID = 31337;

    /// @dev Anvil's first prefunded account. Its private key is public, so only use it on a local chain.
    address public constant ANVIL_DEFAULT_ACCOUNT = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;

    /// @dev CRE forwarders on Sepolia. Deployed workflows deliver reports through the first;
    /// `cre workflow simulate --broadcast` uses the second. Addresses from
    /// https://docs.chain.link/cre/guides/workflow/using-evm-client/forwarder-directory-ts
    address public constant SEPOLIA_CRE_FORWARDER = 0xF8344CFd5c43616a4366C34E3EEE75af79a74482;
    address public constant SEPOLIA_CRE_SIMULATION_FORWARDER = 0x15fC6ae953E024d975e77382eEeC56A9101f9F88;
    /// @dev There are no CRE forwarders on a local chain; tests prank as these placeholder addresses.
    address public constant LOCAL_CRE_FORWARDER = address(uint160(uint256(keccak256("LOCAL_CRE_FORWARDER"))));
    address public constant LOCAL_CRE_SIMULATION_FORWARDER =
        address(uint160(uint256(keccak256("LOCAL_CRE_SIMULATION_FORWARDER"))));

    uint96 public constant MOCK_BASE_FEE = 0.25 ether;
    uint96 public constant MOCK_GAS_PRICE_LINK = 1e9;
    int256 public constant MOCK_WEI_PER_UNIT_LINK = 4e15;
    /// @dev Enough LINK for many mock fulfillments; each costs roughly 62.5 LINK at the mock prices above.
    uint256 public constant LOCAL_SUBSCRIPTION_FUND_AMOUNT = 1000 ether;
}

/**
 * @title HelperConfig
 * @author SonicWizard
 * @notice Supplies the Raffle constructor arguments, the broadcasting account and the CRE forwarders for the current
 * chain.
 * @dev On a local chain it deploys a VRF coordinator mock and leaves `subscriptionId` at 0, so `DeployRaffle`
 * creates and funds one. On Sepolia the subscription ID comes from `SEPOLIA_SUBSCRIPTION_ID` and the account from
 * `SEPOLIA_ACCOUNT`, the address that owns that subscription and holds the LINK that funds it. `getSepoliaEthConfig`
 * returns 0 for either when unset or unparseable (such as an unresolved 1Password reference), so a plain `forge test`
 * still works; `getConfig` rejects a missing account so scripts never broadcast from address(0).
 * Scripts broadcast from `account` explicitly, so tests and fork runs (including `setUp`, which ignores `--sender`)
 * act as the subscription owner, and a live run fails unless `--account` is that address.
 */
contract HelperConfig is CodeConstants, Script {
    struct NetworkConfig {
        uint256 entranceFee;
        uint256 interval;
        address vrfCoordinator;
        bytes32 gasLane;
        uint256 subscriptionId;
        uint32 callbackGasLimit;
        address link;
        address account;
        address creForwarder;
        address creSimulationForwarder;
    }

    NetworkConfig private s_localNetworkConfig;

    error HelperConfig__InvalidChainId(uint256 chainId);
    error HelperConfig__MissingSepoliaAccount();

    /**
     * @notice Returns the config for the current chain.
     * @dev Reverts on Sepolia if `SEPOLIA_ACCOUNT` is unset or not an address.
     * @return The Raffle constructor arguments and broadcasting account for `block.chainid`.
     */
    function getConfig() public returns (NetworkConfig memory) {
        if (block.chainid == ETH_SEPOLIA_CHAIN_ID) {
            NetworkConfig memory config = getSepoliaEthConfig();
            require(config.account != address(0), HelperConfig__MissingSepoliaAccount());
            return config;
        }
        if (block.chainid == LOCAL_CHAIN_ID) {
            return getOrCreateAnvilEthConfig();
        }
        revert HelperConfig__InvalidChainId(block.chainid);
    }

    /**
     * @notice Returns the local config, deploying the VRF mock on first use.
     * @return The Raffle constructor arguments and broadcasting account for a local chain.
     */
    function getOrCreateAnvilEthConfig() public returns (NetworkConfig memory) {
        if (s_localNetworkConfig.vrfCoordinator != address(0)) {
            return s_localNetworkConfig;
        }

        vm.startBroadcast(ANVIL_DEFAULT_ACCOUNT);
        IVRFCoordinatorV2_5Mock vrfCoordinatorMock = IVRFCoordinatorV2_5Mock(
            deployCode(
                "VRFCoordinatorV2_5Mock.sol:VRFCoordinatorV2_5Mock",
                abi.encode(MOCK_BASE_FEE, MOCK_GAS_PRICE_LINK, MOCK_WEI_PER_UNIT_LINK)
            )
        );
        vm.stopBroadcast();

        s_localNetworkConfig = NetworkConfig({
            entranceFee: 0.01 ether,
            interval: 30,
            vrfCoordinator: address(vrfCoordinatorMock),
            // The mock ignores the gas lane.
            gasLane: bytes32(0),
            subscriptionId: 0,
            callbackGasLimit: 500_000,
            // The mock is funded directly with `fundSubscription`, so no LINK token is needed locally.
            link: address(0),
            account: ANVIL_DEFAULT_ACCOUNT,
            creForwarder: LOCAL_CRE_FORWARDER,
            creSimulationForwarder: LOCAL_CRE_SIMULATION_FORWARDER
        });
        return s_localNetworkConfig;
    }

    /**
     * @notice Returns the Sepolia config.
     * @dev Coordinator, gas lane and LINK token come from https://docs.chain.link/vrf/v2-5/supported-networks.
     * @return The Raffle constructor arguments and broadcasting account for Sepolia.
     */
    function getSepoliaEthConfig() public view virtual returns (NetworkConfig memory) {
        return NetworkConfig({
            entranceFee: 0.01 ether,
            interval: 30,
            vrfCoordinator: 0x9DdfaCa8183c41ad55329BdeeD9F6A8d53168B1B,
            // 500 gwei key hash.
            gasLane: 0x787d74caea10b2b357790d5b5247c2f63d1d91572a9846f780606e4d953677ae,
            subscriptionId: vm.envOr("SEPOLIA_SUBSCRIPTION_ID", uint256(0)),
            callbackGasLimit: 500_000,
            link: 0x779877A7B0D9E8603169DdbD7836e478b4624789,
            account: vm.envOr("SEPOLIA_ACCOUNT", address(0)),
            creForwarder: SEPOLIA_CRE_FORWARDER,
            creSimulationForwarder: SEPOLIA_CRE_SIMULATION_FORWARDER
        });
    }
}
