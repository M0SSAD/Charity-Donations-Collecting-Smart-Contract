//SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {Script} from "forge-std/Script.sol";
import {Donations} from "../src/Donations.sol";
import {VRFCoordinatorV2_5Mock} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";
import {LinkToken} from "../test/mocks/LinkToken.sol";

/// @title HelperConfig
/// @notice Provides network-specific configuration for local & test networks used in scripts/tests
/// @dev Stores Chainlink VRF details (coordinator, keyHash, callback gas limit, LINK token) and
///      supports creating local mock deployments for anvil/Foundry tests.
abstract contract CodeConstants {
    /// @notice Mock base fee used by the local VRFCoordinator mock
    uint96 constant MOCK_BASE_FEE = 100000000000000000;
    /// @notice Mock gas price used by the local VRFCoordinator mock
    uint96 constant MOCK_GAS_PRICE = 1000000000;
    /// @notice Mock wei per unit LINK used to simulate LINK price in the mock
    int256 constant MOCK_WEI_PER_UNIT_LINK = 4900000000000000;

    /// @notice Chain id constant for the local anvil chain
    uint256 constant LOCAL_CHAIN_ID = 31337;
    /// @notice Default deployer account used by Foundry scripts (anvil default private key)
    address public FOUNDRY_DEFAULT_SENDER =
        0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
}

error HelperConfig__InvalidChainId();

/// @notice Helper contract to centralize network-specific values for scripts / tests
contract HelperConfig is Script, CodeConstants{
    /// @notice Network configuration values required by the Donations deployment and scripts
    /// @dev `subId` is the Chainlink VRF subscription id. For local testing this can be 0.
    struct NetworkConfig {
        uint256 subId;             // VRF subscription id
        address vrfCoordinator;    // VRF Coordinator contract address
        bytes32 keyHash;           // Gas lane / key hash for VRF
        uint32 callbackGasLimit;   // Gas limit for VRF callback
        uint256 interval;          // Upkeep interval used by Donations contract
        address linkToken;         // LINK token address for the network
        address account;           // Deploy account / subscription owner
    }

    /// @notice Cached config used when creating a local anvil setup
    NetworkConfig public localNetworkConfig;

    /// @notice Mapping of chainId to network configuration
    mapping(uint256 => NetworkConfig) public networkConfigsByChainId;

    /// @notice Construct and pre-populate known network configs (e.g., Sepolia)
    constructor() {
        networkConfigsByChainId[11155111] = getSepoliaEthConfig();
    }

    /// @notice Return a static Sepolia configuration (update `subId` after creating subscription)
    /// @dev This method is pure because it returns hard-coded values; replace subId with real one
    function getSepoliaEthConfig() public pure returns (NetworkConfig memory) {
        return NetworkConfig({
            keyHash: 0x787d74caea10b2b357790d5b5247c2f63d1d91572a9846f780606e4d953677ae,
            subId: 0, // Get From The Deployed Subscription On Chainlink.
            vrfCoordinator: 0x9DdfaCa8183c41ad55329BdeeD9F6A8d53168B1B,
            callbackGasLimit: 2500000,
            interval: 30,
            linkToken: 0x779877A7B0D9E8603169DdbD7836e478b4624789,
            account: 0x462509039F9b54cDD61B24CEcCeC3013FC3af1ec
        });
    }

    /// @notice Deploy (once) and return a local anvil configuration using mocks
    /// @dev Creates VRFCoordinatorV2_5Mock and a mock LINK token, then returns their addresses
    function getOrCreateAnvilConfig() public returns( NetworkConfig memory){
        if (localNetworkConfig.vrfCoordinator != address(0)) {
            return localNetworkConfig;
        }

        // Deploy mocks as the Foundry default sender so they are owned/managed predictably
        vm.startBroadcast(FOUNDRY_DEFAULT_SENDER);

        VRFCoordinatorV2_5Mock vrfCoordinator = new VRFCoordinatorV2_5Mock(
            MOCK_BASE_FEE,
            MOCK_GAS_PRICE,
            MOCK_WEI_PER_UNIT_LINK
        );

        LinkToken linkToken = new LinkToken();

        vm.stopBroadcast();

        NetworkConfig memory anvilConfig = NetworkConfig({
            keyHash: 0x787d74caea10b2b357790d5b5247c2f63d1d91572a9846f780606e4d953677ae,
            subId: 0,
            vrfCoordinator: address(vrfCoordinator),
            callbackGasLimit: 2500000,
            interval: 30,
            linkToken: address(linkToken),
            account: FOUNDRY_DEFAULT_SENDER
        });

        // Cache local config for subsequent calls during the same test run
        localNetworkConfig = anvilConfig;
        return anvilConfig;
    }

    /// @notice Return the appropriate config for the current chain id
    /// @dev On local chain this will deploy mocks if necessary; for known testnets returns static config
    function getConfig() public returns (NetworkConfig memory) {
         if (networkConfigsByChainId[block.chainid].vrfCoordinator != address(0)) {
            return networkConfigsByChainId[block.chainid];
        } else if (block.chainid == LOCAL_CHAIN_ID) {
            return getOrCreateAnvilConfig();
        } else {
            revert HelperConfig__InvalidChainId();
        }
    }
    
    /// @notice Allow updating the stored config for a chain id (used by deploy scripts)
    /// @dev This function is public and unprotected for convenience in local scripts; protect it for production
    function setConfig(uint256 chainId, NetworkConfig memory config) external {
        networkConfigsByChainId[chainId] = config;
    }

}