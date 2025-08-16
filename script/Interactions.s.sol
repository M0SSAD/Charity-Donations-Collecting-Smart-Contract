//SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {Script} from "forge-std/Script.sol";
import {Donations} from "../src/Donations.sol";
import {HelperConfig, CodeConstants} from "./HelperConfig.s.sol";
import {DevOpsTools} from "lib/foundry-devops/src/DevOpsTools.sol";
import {VRFCoordinatorV2_5Mock} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";
import {console2} from "forge-std/console2.sol";
import {LinkToken} from "../test/mocks/LinkToken.sol";
import {VRFCoordinatorV2_5} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFCoordinatorV2_5.sol";

/// @title Interactions
/// @notice Collection of small helper scripts for VRF subscription lifecycle management
/// @dev These scripts are intentionally small and can be executed independently with `forge script`.
///      They encapsulate: creating a subscription, funding it with LINK, and adding a consumer.
contract CreateSubscription is Script, CodeConstants{
    uint256 subId;

    /// @notice Create a subscription using values from HelperConfig
    /// @dev Convenience wrapper that reads the config and delegates to `createSubscription`.
    function createSubscriptionByConfig() public returns(uint256, address) {
        HelperConfig helperConfig = new HelperConfig();
        HelperConfig.NetworkConfig memory config = helperConfig.getConfig();
        address vrfCoordinator = config.vrfCoordinator;
        address account = config.account;
        return createSubscription(vrfCoordinator, account);
    }

    /// @notice Create a subscription on the provided VRF coordinator using `account` as the broadcaster
    /// @dev Uses the mock interface on local chains and the real interface on testnets/mainnet.
    /// @param vrfCoordinator The address of the VRF Coordinator contract
    /// @param account The account that will broadcast the createSubscription tx
    /// @return subId The newly created subscription id and the coordinator used
    function createSubscription(address vrfCoordinator, address account) public returns (uint256 subId, address) {
        console2.log("Creating subscription on chainId: ", block.chainid);
        if(block.chainid == LOCAL_CHAIN_ID) {
            vm.startBroadcast(account);
            subId = VRFCoordinatorV2_5Mock(vrfCoordinator).createSubscription();
            vm.stopBroadcast();
        } else {
            vm.startBroadcast(account);
            subId = VRFCoordinatorV2_5(vrfCoordinator).createSubscription();
            vm.stopBroadcast();
        }
        console2.log("Your subscription Id is: ", subId);
        return (subId, vrfCoordinator);
    }

    /// @notice Entry-point used by `forge script` to run the create-subscription flow
    function run() external returns(uint256, address) {
        return createSubscriptionByConfig();
    }
}

/// @notice FundSubscription helps fund a VRF subscription with LINK tokens.
/// @dev On local chain it uses the mock coordinator's `fundSubscription`; on testnets it performs a
///      `transferAndCall` on the LINK token to the real coordinator.
contract FundSubscription is Script, CodeConstants {
    uint96 public constant FUND_AMOUNT = 3 ether;

    /// @notice Fund subscription using values from `HelperConfig`.
    /// @dev Logs helpful debug info before delegating to `fundSubscription`.
    function fundSubscriptionByConfig() public {
        HelperConfig helperConfig = new HelperConfig();
        HelperConfig.NetworkConfig memory config = helperConfig.getConfig();
        console2.log("Getting Subscription Id To fund: ", config.subId);
        console2.log("Using vrfCoordinator: ", config.vrfCoordinator);
        console2.log("On ChainID: ", block.chainid);
        address vrfCoordinator = config.vrfCoordinator;
        address account = config.account;
        uint256 subId = config.subId;
        address linkToken = config.linkToken;
        fundSubscription(subId, vrfCoordinator, account, linkToken);
    }

    /// @notice Fund the specified subscription. Uses mock helper on local chain and LINK transfer on live nets.
    function fundSubscription(uint256 subId, address vrfCoordinator, address account, address linkToken) public {
        console2.log("Funding subscription: ", subId);
        console2.log("Using vrfCoordinator: ", vrfCoordinator);
        console2.log("On ChainID: ", block.chainid);

        if(block.chainid == LOCAL_CHAIN_ID){
            // On local chain the mock coordinator exposes a direct fund API useful for tests
            vm.startBroadcast(account);
            VRFCoordinatorV2_5Mock(vrfCoordinator).fundSubscription(subId, FUND_AMOUNT * 100);
            vm.stopBroadcast();
        } else {
            // On testnets/mainnet we fund by transferring LINK tokens to the coordinator
            console2.log(LinkToken(linkToken).balanceOf(msg.sender));
            console2.log(msg.sender);
            console2.log(LinkToken(linkToken).balanceOf(vrfCoordinator));
            console2.log(vrfCoordinator);
            vm.startBroadcast(account);
            LinkToken(linkToken).transferAndCall(vrfCoordinator, FUND_AMOUNT, abi.encode(subId));
            vm.stopBroadcast();
        }

    }

    /// @notice Entry point for `forge script` to fund using configured values
    function run() external{
        return fundSubscriptionByConfig();
    }
}

/// @notice AddConsumer registers a deployed contract as an authorized VRF consumer
/// @dev This script reads values from `HelperConfig` and invokes `addConsumer` on the coordinator mock
contract AddConsumer is Script, CodeConstants {
    /// @notice Helper that reads config and calls `addConsumer` with configured values
    function addConsumerByConfig(address contractToAdd) public {
        HelperConfig helperConfig = new HelperConfig();
        HelperConfig.NetworkConfig memory config = helperConfig.getConfig();
        console2.log("Funding subscription: ", config.subId);
        console2.log("Using vrfCoordinator: ", config.vrfCoordinator);
        console2.log("On ChainID: ", block.chainid);
        addConsumer(contractToAdd, config.vrfCoordinator, config.subId, config.account);
    }

    /// @notice Register `contractToAdd` as a consumer on the VRF coordinator for `subId`
    function addConsumer(address contractToAdd, address vrfCoordinator, uint256 subId, address account) public {
        console2.log("Adding consumer: ", contractToAdd);
        console2.log("Using vrfCoordinator: ", vrfCoordinator);
        console2.log("On ChainID: ", block.chainid);

        vm.startBroadcast(account);
        VRFCoordinatorV2_5Mock(vrfCoordinator).addConsumer(subId, contractToAdd);
        vm.stopBroadcast();
    }

    /// @notice Entrypoint for `forge script` which finds the most recently deployed Donations contract
    ///         and registers it as a consumer.
    function run() external {
        address latestDonationsAddress = DevOpsTools.get_most_recent_deployment("Donations", block.chainid);
        addConsumerByConfig(latestDonationsAddress);
    }
}