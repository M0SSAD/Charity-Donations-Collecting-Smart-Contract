//SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {Script} from "forge-std/Script.sol";
import {Donations} from "../src/Donations.sol";
import {HelperConfig, CodeConstants} from "./HelperConfig.s.sol";
import {CreateSubscription, FundSubscription, AddConsumer} from "./Interactions.s.sol";
import {console2} from "forge-std/console2.sol";

/// @title DeployDonations
/// @notice Script to deploy the `Donations` contract. Handles creating/funding a VRF subscription
///         and adding the deployed Donations contract as a VRF consumer when necessary.
/// @dev Uses `HelperConfig` to obtain network-specific values and `Interactions` scripts for
///      subscription management. Designed for Foundry script-based deployments.
contract DeployDonations is Script, CodeConstants{

    /// @notice Deploy the Donations contract and ensure VRF subscription is ready.
    /// @dev If `subId` is 0 in the config, the script will create and fund a new subscription
    ///      (using the `CreateSubscription` and `FundSubscription` helper scripts) and then
    ///      store the updated config via `helperConfig.setConfig`.
    /// @return donations The deployed Donations contract instance
    /// @return helperConfig The helper config used for this deployment
    function deployContract() public returns (Donations, HelperConfig) {
        HelperConfig helperConfig = new HelperConfig();
        AddConsumer addConsumer = new AddConsumer();
        HelperConfig.NetworkConfig memory config = helperConfig.getConfig();

        // If no subscription exists in the config, create and fund one then persist config
        if (config.subId == 0)
        {
            CreateSubscription createSubscription = new CreateSubscription();
            (config.subId, config.vrfCoordinator) = createSubscription.run();
            
            FundSubscription fundSubscription = new FundSubscription();
            fundSubscription.fundSubscription(config.subId, config.vrfCoordinator, config.account, config.linkToken);
            helperConfig.setConfig(block.chainid, config);
        }

        // Deploy the Donations contract as the configured deployer account
        vm.startBroadcast(config.account);
        Donations donations = new Donations(
            config.subId,
            config.vrfCoordinator,
            config.keyHash,
            config.callbackGasLimit,
            config.interval
        );
        vm.stopBroadcast();
        console2.log("Donations contract deployed at:", address(donations));

        // Register the deployed Donations contract as a consumer for the VRF subscription
        addConsumer.addConsumer(address(donations), config.vrfCoordinator, config.subId, config.account);

        return (donations, helperConfig);
    }

    /// @notice Convenience wrapper to run `deployContract` via `forge script` runner
    function run() external returns(Donations, HelperConfig) {
        return deployContract();
    }
}