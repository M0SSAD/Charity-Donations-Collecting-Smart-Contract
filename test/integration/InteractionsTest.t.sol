// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {Donations} from "../../src/Donations.sol";
import {GiftNFT} from "../../src/GiftNFT.sol";
import {DeployDonations} from "../../script/DeployDonations.s.sol";
import {HelperConfig, CodeConstants} from "../../script/HelperConfig.s.sol";
import {VRFCoordinatorV2_5Mock} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";
import {console2} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title Donations Integration Tests
/// @notice Integration tests exercising the full donations -> VRF -> NFT flow.
/// @dev Tests are designed to run locally against Foundry/Anvil with VRF mocks; several
///      tests are guarded by `onlyLocal` to skip on non-local chains.
contract DonationsIntegrationTest is Test, CodeConstants {
    /// @notice Donations contract under test (deployed via `DeployDonations` script)
    Donations public donations;

    /// @notice GiftNFT instance used by the Donations contract to mint prizes
    GiftNFT public giftNFT;

    /// @notice HelperConfig instance that provides network-specific values for VRF/LINK
    HelperConfig public helperConfig;

    /// @notice Deploy script helper used to deploy the Donations contract in tests
    DeployDonations public deployer;

    // --- Network / VRF configuration loaded from HelperConfig ---
    /// @notice Address of the VRF Coordinator (mock on local)
    address public vrfCoordinator;
    /// @notice Gas lane / keyHash used by VRF
    bytes32 public gasLane;
    /// @notice Chainlink subscription id used by VRF requests
    uint256 public subscriptionId;
    /// @notice Callback gas limit for VRF fulfillRandomWords
    uint32 public callBackGasLimit;
    /// @notice LINK token address used for funding (mock on local)
    address public linkToken;
    /// @notice Deployer account (owner/subscription owner) used in scripts
    address public deployerKey;

    // --- Test actors: simulated accounts used across integration tests ---
    address public DONOR1 = makeAddr("donor1");
    address public DONOR2 = makeAddr("donor2");
    address public DONOR3 = makeAddr("donor3");
    address public CHARITY = makeAddr("charity");

    /// @notice Starting ether balance assigned to each donor for tests
    uint256 public constant STARTING_BALANCE = 10 ether;
    /// @notice Standard donation value used by integration flows
    uint256 public constant DONATION_VALUE = 0.1 ether;

    /// @notice Test setup executed before each test case
    /// @dev Deploys the Donations contract via the same deployment script used in production
    ///      and fetches network/VRF configuration from `HelperConfig`. Also allocates starting
    ///      balances for simulated donor accounts.
    function setUp() external {
        // Deploy using the same script as production
        deployer = new DeployDonations();
        (donations, helperConfig) = deployer.deployContract();

        // Get config
        HelperConfig.NetworkConfig memory config = helperConfig.getConfig();
        vrfCoordinator = config.vrfCoordinator;
        gasLane = config.keyHash;
        subscriptionId = config.subId;
        callBackGasLimit = config.callbackGasLimit;
        linkToken = config.linkToken;
        deployerKey = config.account;

        // Get the NFT contract from Donations
        giftNFT = donations.getGiftNFT();

        // Fund donors
        vm.deal(DONOR1, STARTING_BALANCE);
        vm.deal(DONOR2, STARTING_BALANCE);
        vm.deal(DONOR3, STARTING_BALANCE);
    }

    /// @notice Modifier to run tests only on the local chain (Anvil/Foundry)
    /// @dev Skips the test when running on external networks where VRF mocks are not available
    modifier onlyLocal() {
        if (block.chainid != LOCAL_CHAIN_ID) {
            vm.skip(true);
            return;
        }
        _;
    }

    /// @notice Helper modifier that performs three sequential donations from three test donors
    /// @dev Useful for tests that require a populated donors array before invoking upkeep/VRF logic
    modifier donateWith3Donors() {
        vm.startPrank(DONOR1);
        donations.donate{value: DONATION_VALUE}();
        vm.stopPrank();

        vm.startPrank(DONOR2);
        donations.donate{value: DONATION_VALUE}();
        vm.stopPrank();

        vm.startPrank(DONOR3);
        donations.donate{value: DONATION_VALUE}();
        vm.stopPrank();

        _;
    }

    /// @notice Integration flow: multiple donors donate -> upkeep triggers -> VRF fulfills -> NFT awarded
    /// @dev Runs only on local chain since it relies on `VRFCoordinatorV2_5Mock` for fulfillRandomWords
    function testFullDonationToNFTFlow() external onlyLocal {
        // Arrange
        uint256 initialDonorsLength = donations.getDonorsCount();
        uint256 initialNFTTokens = giftNFT.getLatestTokenId();

        console2.log("=== Starting Full Donation Flow Integration Test ===");
        console2.log("Initial donors length:", initialDonorsLength);
        console2.log("Initial NFT Generated Tokens:", initialNFTTokens);
        console2.log("Charity address:", donations.getCharityWallet());
        console2.log("Initial Donation State: ", uint256(donations.getDonationStatus()));

        // ACT 1 : Multiple Donations
        vm.prank((DONOR1));
        donations.donate{value: DONATION_VALUE}();
        vm.prank((DONOR2));
        donations.donate{value: DONATION_VALUE}();
        vm.prank((DONOR3));
        donations.donate{value: DONATION_VALUE}();

        console2.log("Final donors length:", donations.getDonorsCount());

        // ACT 2 : Trigger VRF
        // Simulate enough time passing for upkeep
        vm.warp(block.timestamp + donations.getInterval() + 1);
        vm.roll(block.number + 1);
        (bool upKeepNeeded,) = donations.checkUpkeep("");
        assertTrue(upKeepNeeded, "Upkeep should be needed after donations");

        vm.recordLogs();
        donations.performUpkeep("");
        assertEq(uint256(donations.getDonationStatus()), 1);
        assertEq(donations.getDonorsCount(), 3, "Donors should still be present");
        assertEq(donations.getRecentWinner(), address(0), "No winner yet on testnet");

        // ACT 3 : Local Fulfill VRF Request
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 requestId = uint256(logs[1].topics[1]);

        console2.log("VRF Request ID:", requestId);

        if (block.chainid == LOCAL_CHAIN_ID) {
            VRFCoordinatorV2_5Mock(vrfCoordinator).fulfillRandomWords(requestId, address(donations));
        }

        // Assert:
        assertEq(uint256(donations.getDonationStatus()), 0, "State should be OPEN again");
        assertEq(donations.getDonorsCount(), 0, "Donors array should be reset");
        assertTrue(donations.getRecentWinner() != address(0), "Should have a winner");

        // 2. NFT was minted to winner
        address winner = donations.getRecentWinner();
        uint256 winnerNFTBalance = giftNFT.balanceOf(winner);
        assertEq(winnerNFTBalance, 1, "Winner should have 1 NFT");

        // 3. NFT contract state updated
        uint256 latestTokenId = giftNFT.getLatestTokenId();
        assertEq(giftNFT.ownerOf(latestTokenId), winner, "Winner should own the latest NFT");

        // 4. Verify winner is one of our donors
        assertTrue(winner == DONOR1 || winner == DONOR2 || winner == DONOR3, "Winner should be one of the donors");

        console2.log("=== Integration Test Complete ===");
        console2.log("Winner:", winner);
        console2.log("Winner NFT balance:", winnerNFTBalance);
        console2.log("Latest Token ID:", latestTokenId);
    }

    /// @notice Ensure cross-contract behavior: Donations invokes GiftNFT correctly and access control enforced
    /// @dev Verifies that only Donations (owner) can mint NFTs and that the NFT contract state updates
    ///      after VRF fulfillment. Uses `donateWith3Donors` helper to prepare state.
    function testMultipleContractsInteraction() external donateWith3Donors onlyLocal {
        console2.log("=== Testing Contract Interactions ===");

        console2.log("=== TEST 1 : Only Donations Contract can mint Gifts ===");
        vm.expectRevert();
        vm.prank(DONOR1);
        giftNFT.mintGiftNFT(DONOR1);
        console2.log("Reverted as expected when non-owner tried to mint gift NFT");

        console2.log("=== TEST 2 : GiftNFT Reports to Donations Correctly ===");
        vm.warp(block.timestamp + donations.getInterval() + 1);
        vm.recordLogs();
        donations.performUpkeep("");
        Vm.Log[] memory entries = vm.getRecordedLogs();
        uint256 requestId = uint256(entries[1].topics[1]);
        console2.log("VRF Request ID:", requestId);

        // Before VRF fulfillment
        uint256 initialTokenId = giftNFT.getLatestTokenId();
        console2.log("Initial Token ID:", initialTokenId);

        // Fulfill VRF
        VRFCoordinatorV2_5Mock(vrfCoordinator).fulfillRandomWords(requestId, address(donations));
        uint256 finalTokenId = giftNFT.getLatestTokenId();
        console2.log("Final Token ID:", finalTokenId);
        assertEq(finalTokenId, initialTokenId + 1, "New NFT should be minted");
        address winner = donations.getRecentWinner();
        console2.log("Winner:", winner);
        assertEq(giftNFT.ownerOf(finalTokenId), winner, "Winner should own the latest NFT");

        console2.log("=== Contract Interaction Test Complete ===");
    }

    /// @notice Verifies charity wallet receives Ether and Donations contract does not retain funds
    /// @dev This test runs on any chain (not gated) and examines balances after several donations
    function testCharityFundIntegration() external {
        console2.log("=== Testing Charity Fund Integration ===");

        address charity = donations.getCharityWallet();
        console2.log("Reseting Charity Balance For Clarity.");
        vm.deal(charity, 0);

        uint256 initialCharityBalance = address(deployerKey).balance;
        console2.log("Initial charity balance:", initialCharityBalance);

        vm.prank(DONOR1);
        donations.donate{value: 1 ether}();
        vm.prank(DONOR2);
        donations.donate{value: 1 ether}();
        vm.prank(DONOR3);
        donations.donate{value: 1 ether}();

        uint256 finalCharityBalance = address(deployerKey).balance;
        assertEq(finalCharityBalance, initialCharityBalance + 3 ether, "Charity balance should be updated");

        assertEq(address(donations).balance, 0, "Donations contract should not hold funds");

        console2.log("Final charity balance:", finalCharityBalance);
        console2.log("=== Charity Integration Test Complete ===");
    }

    /// @notice Runs multiple donation cycles to ensure repeatability of the VRF/NFT flow
    /// @dev Each cycle: donors donate, performUpkeep triggers VRF request, fulfillRandomWords mints NFT
    ///      The test asserts the correct number of NFTs are minted and state resets after each cycle.
    function testMultipleCycleIntegration() external onlyLocal {
        console2.log("=== Testing Multiple Donation Cycles ===");

        uint256 numberOfCycles = 3;
        uint256 initialNumberOfGeneratedTokens = giftNFT.getLatestTokenId();
        address[] memory winners = new address[](numberOfCycles);

        for (uint256 i = 0; i < numberOfCycles; i++) {
            vm.prank(DONOR1);
            donations.donate{value: DONATION_VALUE}();
            vm.prank(DONOR2);
            donations.donate{value: DONATION_VALUE}();
            vm.prank(DONOR3);
            donations.donate{value: DONATION_VALUE}();

            vm.warp(donations.getLastTimeStamp() + donations.getInterval() + 1);
            vm.roll(block.number + 1);

            (bool upKeepNeeded,) = donations.checkUpkeep("");
            assertTrue(upKeepNeeded, "Upkeep should be needed after donations");
            vm.recordLogs();
            donations.performUpkeep("");

            Vm.Log[] memory logs = vm.getRecordedLogs();
            uint256 requestId = uint256(logs[1].topics[1]);
            console2.log("Request ID:", requestId);

            VRFCoordinatorV2_5Mock(vrfCoordinator).fulfillRandomWords(requestId, address(donations));
            winners[i] = (donations.getRecentWinner());

            console2.log("Cycle", i + 1, "winner:", winners[i]);
            console2.log("Winner NFT balance:", giftNFT.balanceOf(winners[i]));

            assertEq(uint256(donations.getDonationStatus()), 0, "State should be OPEN after cycle");
            console2.log("----------------------------");
        }
        uint256 finalNumberOfGeneratedTokens = giftNFT.getLatestTokenId();
        assertEq(uint256(donations.getDonationStatus()), 0, "State should be OPEN after cycle");
        console2.log("Final State:", uint256(donations.getDonationStatus()));
        assertEq(donations.getDonorsCount(), 0, "Donors array should be empty");
        console2.log("Final Number of Generated Tokens:", finalNumberOfGeneratedTokens);
        assertEq(
            finalNumberOfGeneratedTokens,
            initialNumberOfGeneratedTokens + numberOfCycles,
            "Number of generated tokens should match"
        );

        console2.log("=== Multiple Cycle Integration Test Complete ===");
    }
}
