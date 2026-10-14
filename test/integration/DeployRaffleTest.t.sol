// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {DeployRaffle} from "../../script/DeployRaffle.s.sol";
import {CodeConstants, HelperConfig} from "../../script/HelperConfig.s.sol";

contract DeployRaffleTest is CodeConstants, Test {
    function test_RevertWhen_DeployingToLiveNetworkWithoutSubscriptionId() external {
        vm.chainId(ETH_SEPOLIA_CHAIN_ID);
        DeployRaffle deployer = new DeployRaffle();
        HelperConfig.NetworkConfig memory config = new HelperConfig().getSepoliaEthConfig();
        config.subscriptionId = 0;

        // `run` deploys its own HelperConfig, and Forge loads SEPOLIA_SUBSCRIPTION_ID from .env, so mock the config
        // at the address that HelperConfig will get. `injectCode = false` keeps that address empty so `run` can deploy.
        address helperConfig = vm.computeCreateAddress(address(deployer), 1);
        vm.mockCall(helperConfig, abi.encodeCall(HelperConfig.getConfig, ()), abi.encode(config), false);

        vm.expectRevert(DeployRaffle.DeployRaffle__MissingSubscriptionId.selector);
        deployer.run();
    }
}
