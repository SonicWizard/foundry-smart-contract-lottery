// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {CodeConstants, HelperConfig} from "../../script/HelperConfig.s.sol";

/// @dev Uses a fixed Sepolia account instead of `SEPOLIA_ACCOUNT`, so tests don't depend on the environment.
contract FixedAccountHelperConfig is HelperConfig {
    address private immutable i_account;

    constructor(address account) {
        i_account = account;
    }

    function getSepoliaEthConfig() public view override returns (NetworkConfig memory config) {
        config = super.getSepoliaEthConfig();
        config.account = i_account;
    }
}

contract HelperConfigTest is CodeConstants, Test {
    HelperConfig private helperConfig;

    function setUp() external {
        helperConfig = new HelperConfig();
    }

    function test_GetSepoliaEthConfigReadsEnvironment() external view {
        HelperConfig.NetworkConfig memory config = helperConfig.getSepoliaEthConfig();

        assertEq(config.subscriptionId, vm.envOr("SEPOLIA_SUBSCRIPTION_ID", uint256(0)));
        assertEq(config.account, vm.envOr("SEPOLIA_ACCOUNT", address(0)));
        assertNotEq(config.link, address(0));
    }

    function test_GetConfigReturnsSepoliaConfigOnSepolia() external {
        address account = makeAddr("sepoliaAccount");
        HelperConfig sepoliaHelperConfig = new FixedAccountHelperConfig(account);
        vm.chainId(ETH_SEPOLIA_CHAIN_ID);

        HelperConfig.NetworkConfig memory config = sepoliaHelperConfig.getConfig();

        assertEq(abi.encode(config), abi.encode(sepoliaHelperConfig.getSepoliaEthConfig()));
        assertEq(config.account, account);
    }

    function test_RevertWhen_SepoliaAccountMissing() external {
        HelperConfig sepoliaHelperConfig = new FixedAccountHelperConfig(address(0));
        vm.chainId(ETH_SEPOLIA_CHAIN_ID);

        vm.expectRevert(HelperConfig.HelperConfig__MissingSepoliaAccount.selector);
        sepoliaHelperConfig.getConfig();
    }

    function test_GetOrCreateAnvilEthConfigDeploysMockOnce() external {
        address vrfCoordinator = helperConfig.getOrCreateAnvilEthConfig().vrfCoordinator;

        assertGt(vrfCoordinator.code.length, 0);
        assertEq(helperConfig.getOrCreateAnvilEthConfig().vrfCoordinator, vrfCoordinator);
    }

    function testFuzz_RevertWhen_ChainIdUnsupported(uint64 chainId) external {
        vm.assume(chainId != ETH_SEPOLIA_CHAIN_ID && chainId != LOCAL_CHAIN_ID);
        vm.chainId(chainId);

        vm.expectRevert(abi.encodeWithSelector(HelperConfig.HelperConfig__InvalidChainId.selector, chainId));
        helperConfig.getConfig();
    }
}
