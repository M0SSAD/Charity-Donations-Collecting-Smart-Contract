//SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {Donations} from "../../src/Donations.sol";
import {DeployDonations} from "../../script/DeployDonations.s.sol";
import {Donations_DonationMustBeGreaterThanZero, Donations_TransferMoneyToCharityFailed, Donations_DonationIsPending, Donations_UpkeepNotNeeded, Donations_DonationIsOpenCannotPickAWinner} from "../../src/Donations.sol";
import {RejectTransactionContract} from "../mocks/RejectTransactionContract.sol";
import {HelperConfig, CodeConstants} from "../../script/HelperConfig.s.sol";
import {Vm} from "forge-std/Vm.sol";
import {VRFCoordinatorV2_5Mock} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";
import {GiftNFT} from "../../src/GiftNFT.sol";
import {console2} from "forge-std/console2.sol";
import {CreateSubscription, FundSubscription, AddConsumer} from "../../script/Interactions.s.sol";


/// @title DonationsTest
/// @notice Unit tests for the `Donations` contract. Uses Forge's `Test` utilities
///         to simulate accounts, time travel, and Chainlink VRF coordinator mocks.
/// @dev This test file focuses on behavior: donations, upkeep, VRF request/fulfillment,
///      and NFT awarding. Tests are intended to run both locally (anvil) and against
///      forked or testnets where appropriate mocks/configs exist.
contract DonationsTest is Test, CodeConstants {
    /// @dev Starting ether balance used for test accounts.
    uint256 constant STARTING_BALANCE = 50 ether;

    /// @dev Standard donation amount used across tests.
    uint256 constant DONATION_AMOUNT = 0.03 ether;

    /// @dev Contract under test.
    Donations public donations;

    /// @dev Helper configuration that provides VRF / LINK / subscription addresses for tests.
    HelperConfig public helperConfig;

    /// @dev Reference to the Gift NFT contract used by Donations to mint prizes.
    GiftNFT public giftNFT;

    /// @dev A canonical donor address used in tests.
    address public DONOR = address (0x01);

    /// @dev Charity wallet address that receives donations; set by deployment script.
    address public CHARITY_WALLET;

    // VRF / timing configuration values fetched from HelperConfig
    uint256 subId;
    address vrfCoordinator;
    bytes32 gasLane;
    uint32 callbackGasLimit;
    uint256 interval;

    uint256 constant FUND_AMOUNT = 300 ether;

    event Donations_VrfCoordinatorWasCorrectlySet(address indexed vrfCoordinator);
    event Donations_DonationReceived(address indexed donor, uint256 amount);
    event Donations_CharityWalletUpdated(address indexed newCharityWallet);
    event Donations_DonorAdded(address indexed donor, uint256 amount);
    event Donations_DonorIsFoundAddingNewFunds(address indexed donor, uint256 amount);
    event Donations_VrfRequestCreated(uint256 indexed requestId);
    event Donations_WinnerPicked(address indexed winner);
    event Donations_NFTGiftedForTheRecentWinner(address indexed winner, uint256 tokenId);


    /// @notice Deploy the Donations contract and load test configuration.
    /// @dev Uses the `DeployDonations` script so tests run with the same deployment logic
    ///      used in production scripts. Fetches VRF and LINK params from `HelperConfig`.
    function setUp() public {
        DeployDonations deployer = new DeployDonations();
        (donations, helperConfig) = deployer.deployContract();
        CHARITY_WALLET = donations.getCharityWallet();

        subId = helperConfig.getConfig().subId;
        vrfCoordinator = helperConfig.getConfig().vrfCoordinator;
        gasLane = helperConfig.getConfig().keyHash;
        callbackGasLimit = helperConfig.getConfig().callbackGasLimit;
        interval = helperConfig.getConfig().interval;

    // Debug: show important addresses and params used in tests
    console2.log("[setUp] Donations contract: ", address(donations));
    console2.log("[setUp] Charity wallet: ", CHARITY_WALLET);
    console2.log("[setUp] VRF Coordinator: ", vrfCoordinator);
    console2.log("[setUp] subscriptionId: ", subId);
    }
    
    /*//////////////////////////////////////////////////////////////
                            TEST CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Verifies the constructor correctly sets the owner and charity wallet.
    /// @dev This is a view-only assertion checking contract's immutable state after deploy.
    function testConstructorSetsOwnerAndCharityWallet() external view {
    console2.log("[test] constructor - owner: ", donations.getOwner());
    console2.log("[test] constructor - charity wallet: ", donations.getCharityWallet());
        assertEq(donations.getOwner(), FOUNDRY_DEFAULT_SENDER);
        assertEq(donations.getCharityWallet(), CHARITY_WALLET);
    }   

    /*//////////////////////////////////////////////////////////////
                              TEST DONATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Ensures a donation call with 0 value reverts with the correct custom error.
    /// @dev Uses `hoax` to impersonate a donor with sufficient balance and expects revert.
    function testDonateFailsWhenZeroDonations() external {
    console2.log("[test] donate fails when zero donations - donor: ", DONOR);
        hoax(DONOR, STARTING_BALANCE);

        vm.expectRevert(Donations_DonationMustBeGreaterThanZero.selector);
        donations.donate{value: 0}();
    }

    /// @notice Confirms a successful donation updates internal donor tracking
    ///         and transfers the donated ETH to the charity wallet.
    /// @dev Asserts event emission, donor registration, and charity balance change.
    function testDonateSucceedsUpdatesArraysAndTransfersMoney() external {
    console2.log("[test] donate succeeds - donor: ", DONOR, " amount: ", DONATION_AMOUNT);
        hoax(DONOR, STARTING_BALANCE);
        uint256 initialCharityBalance = CHARITY_WALLET.balance;
        uint256 finalCharityBalance;

        vm.expectEmit(true, false, false, false, address(donations));
        emit Donations_DonationReceived(DONOR, DONATION_AMOUNT);
        vm.expectEmit(true, false, false, false, address(donations));
        emit Donations_CharityWalletUpdated(CHARITY_WALLET);
        donations.donate{value: DONATION_AMOUNT}();
        finalCharityBalance = CHARITY_WALLET.balance;
    console2.log("[test] charity balance delta: ", finalCharityBalance - initialCharityBalance);
        
        assertEq(donations.getDonors(0), DONOR);
        assertEq(donations.getDonorsToAmount(DONOR), DONATION_AMOUNT);

        assertEq(donations.getCharityWallet(), CHARITY_WALLET);
        assertEq(finalCharityBalance-initialCharityBalance, DONATION_AMOUNT);
    }
    /// @notice Tests multiple donors donating, including repeated donations by the same donor.
    /// @dev Ensures donors are added exactly once and repeated donations increase donor's total.
    function testDonateSucceedsByMultipleDonors() external {
    console2.log("[test] multiple donors flow starting");
        hoax(DONOR, STARTING_BALANCE);
        vm.expectEmit(true, false, false, false, address(donations));
        emit Donations_DonorAdded(DONOR, DONATION_AMOUNT);
        donations.donate{value: DONATION_AMOUNT}();

        hoax(address(0x02), STARTING_BALANCE);
        vm.expectEmit(true, false, false, false, address(donations));
        emit Donations_DonorAdded(address(0x02), DONATION_AMOUNT);
        donations.donate{value: DONATION_AMOUNT}();
        
        hoax(DONOR, STARTING_BALANCE);
        vm.expectEmit(true, false, false, false, address(donations));
        emit Donations_DonorIsFoundAddingNewFunds(DONOR, DONATION_AMOUNT);
        donations.donate{value: DONATION_AMOUNT}();
    console2.log("[test] donors count after operations: ", donations.getDonorsCount());

        assertEq(donations.getDonors(0), DONOR);
        assertEq(donations.getDonorsToAmount(DONOR), DONATION_AMOUNT + DONATION_AMOUNT);
        assertEq(donations.getDonors(1), address(0x02));
        assertEq(donations.getDonorsToAmount(address(0x02)), DONATION_AMOUNT);
        assertEq(donations.getDonorsCount(), 2);
    }
    /// @notice Verifies that donations are rejected when the contract is in PENDING status.
    /// @dev Owner toggles status to PENDING and a donor attempt should revert with custom error.
    function testDonationFailsWhenPending() external {
    console2.log("[test] donation fails when status pending - setting pending");
        vm.prank(donations.getOwner());
        donations.setDonationStatus(Donations.DonationStatus.PENDING);
        
        hoax(DONOR, STARTING_BALANCE);
        vm.expectRevert(Donations_DonationIsPending.selector);
        donations.donate{value: DONATION_AMOUNT}();
    }
    /// @notice Ensures the donate flow reverts when the charity wallet rejects transfers.
    /// @dev Sets the charity wallet to a mock contract that reverts on receive and expects revert.
    function testTransferMoneyToCharityFailsWhenNotEnoughBalance() external {
    console2.log("[test] transfer to charity fails when recipient rejects payments");
        // Set charity wallet to a contract that rejects transactions
        address rejectContract = address(new RejectTransactionContract());
        vm.prank(donations.getOwner());
        donations.changeCharityWallet(rejectContract);

        hoax(DONOR, STARTING_BALANCE);
        vm.expectRevert(Donations_TransferMoneyToCharityFailed.selector);
        donations.donate{value: DONATION_AMOUNT}();

    }

    /*//////////////////////////////////////////////////////////////
                            TEST CHECKUPKEEP
    //////////////////////////////////////////////////////////////*/

    /// @notice checkUpkeep should return false when there are no donors recorded.
    /// @dev This covers the early return condition in `checkUpkeep`.
    function testCheckUpKeepReturnsFalseWhenNoDonors() external {
    console2.log("[test] checkUpkeep - no donors");
        (bool upkeepNeeded, ) = donations.checkUpkeep("");
        assertFalse(upkeepNeeded);
    }

    /// @notice checkUpkeep should return false when donations are in PENDING status.
    /// @dev After a donation, owner sets status to PENDING and upkeep must be false.
    function testCheckUpKeepReturnsFalseWhenDonationIsPending() external {
    console2.log("[test] checkUpkeep - donation pending");
        hoax(DONOR, STARTING_BALANCE);
        donations.donate{value: DONATION_AMOUNT}();
        vm.prank(donations.getOwner());
        donations.setDonationStatus(Donations.DonationStatus.PENDING);

        (bool upkeepNeeded, ) = donations.checkUpkeep("");
        assertFalse(upkeepNeeded);
    }

    /// @notice checkUpkeep should return false if the required interval hasn't passed yet.
    /// @dev Ensures time-based condition prevents upkeep until interval elapses.
    function testCheckUpKeepReturnsFalseWhenIntervalNotPassed() external {
    console2.log("[test] checkUpkeep - interval not passed");
        hoax(DONOR, STARTING_BALANCE);
        donations.donate{value: DONATION_AMOUNT}();

        (bool upkeepNeeded, ) = donations.checkUpkeep("");
        assertFalse(upkeepNeeded);
    }
    
    /// @notice checkUpkeep returns true when donors exist and the interval has elapsed.
    /// @dev This test advances time past the interval and expects upkeepNeeded to be true.
    function testCheckUpKeepReturnsTrueWhenIntervalPassedAndDonorsExists() external {
    console2.log("[test] checkUpkeep - interval passed and donors exist");
        hoax(DONOR, STARTING_BALANCE);
        donations.donate{value: DONATION_AMOUNT}();
        
        vm.warp(block.timestamp + donations.getInterval() + 1);
        (bool upkeepNeeded, ) = donations.checkUpkeep("");
        assertTrue(upkeepNeeded);
    }

    /*//////////////////////////////////////////////////////////////
                           TEST PERFORMUPKEEP
    //////////////////////////////////////////////////////////////*/

    /// @notice Test helper modifier that ensures performUpkeep preconditions are met.
    /// @dev Donates once and advances time so `checkUpkeep` becomes true. Use on tests that
    ///      require the contract to be ready to perform upkeep.
    modifier upKeepNeeded() {
        hoax(DONOR, STARTING_BALANCE);
        donations.donate{value: DONATION_AMOUNT}();

        vm.warp(block.timestamp + donations.getInterval() + 1);
        (bool upkeepNeeded, ) = donations.checkUpkeep("");
        assertTrue(upkeepNeeded);
        _;
    }

    /// @notice Verifies performUpkeep reverts with `UpkeepNotNeeded` when upkeep is not required.
    /// @dev Compares encoded revert error containing current donors count, donation status and interval.
    function testPerformUpkeepFailsWhenNoUpkeepNeeded() external {
    console2.log("[test] performUpkeep should fail when no upkeep needed");
        (bool upkeepNeeded, ) = donations.checkUpkeep("");
        assertFalse(upkeepNeeded);

        bytes memory expectedError = abi.encodeWithSelector(
            Donations_UpkeepNotNeeded.selector,
            donations.getDonorsCount(),
            donations.getDonationStatus(),
            donations.getInterval()
        );

        vm.expectRevert(expectedError);
        donations.performUpkeep("");
    }

    /// @notice Checks that performUpkeep succeeds when `checkUpkeep` returns true.
    /// @dev Uses `upKeepNeeded` modifier to set the test preconditions.
    function testPerformUpKeepSucceedsWhenUpKeepNeeded() external upKeepNeeded() {
    console2.log("[test] performUpkeep - expected to succeed");
        donations.performUpkeep("");
    }

    /// @notice Ensures performUpkeep triggers a VRF request and that the request id is emitted.
    /// @dev Uses `vm.recordLogs()` to capture events from the mock coordinator and the donations contract.
    function testPerformUpKeepCreatesRequestAndEmitsItsId() external upKeepNeeded() {
    console2.log("[test] performUpkeep - creating request and checking emitted id");
        vm.recordLogs();
        donations.performUpkeep("");
        Vm.Log[] memory entries = vm.getRecordedLogs();

        uint256 requestIdEventEmittedFromMockCoordinator = abi.decode(entries[0].data, (uint256));
        bytes32 requestIdEventEmittedFromDonations = entries[1].topics[1];

        assert(uint256(requestIdEventEmittedFromMockCoordinator) == 1);
        assertEq(uint256(requestIdEventEmittedFromDonations), 1);
        assertEq(uint256(donations.getDonationStatus()), 1);

    }

    /*//////////////////////////////////////////////////////////////
                       TEST FULFULLRANDOMWORDS
    //////////////////////////////////////////////////////////////*/

    /// @notice Modifier to skip tests when not running on local chain (Anvil / Foundry local).
    /// @dev Useful when tests use Chainlink VRF mocks that exist only on local test runner.
    modifier onlyLocal(){
        if (block.chainid != LOCAL_CHAIN_ID) {
            vm.skip(true);
            return;
        }
        _;
    }

    /// @notice Validates that fulfilling random words without a valid request id reverts.
    /// @dev This test is local-only and expects the VRF mock to reject invalid requests.
    function testFulFillRandomWordsCanOnlyBeCalledAfterPerformUpKeep(uint256 randomRequestId) external onlyLocal() {
    console2.log("[test] fulfillRandomWords can only be called after performUpkeep (local-only)");

        vm.expectRevert(
            VRFCoordinatorV2_5Mock.InvalidRequest.selector
        );
        VRFCoordinatorV2_5Mock(vrfCoordinator).fulfillRandomWords(randomRequestId, address(donations));
    }

    /// @notice Full integration test: multiple donors, performUpkeep, fulfillRandomWords and award NFT.
    /// @dev This test runs only locally against the VRFCoordinatorV2_5Mock. It asserts the donation
    ///      process returns to OPEN state and the winner receives the minted NFT prize.
    function testFulFillRandomWordsSucceedsAndPicksWinner() external onlyLocal() {
    console2.log("[test] fulfillRandomWords succeeds and picks a winner (local-only)");
        
        uint256 startingIndex = 2;
        uint256 additionalEntrants = 4;

        for(uint256 i = startingIndex; i < startingIndex + additionalEntrants; i++) {
            hoax(address(uint160(i)), STARTING_BALANCE);
            donations.donate{value: DONATION_AMOUNT}();
        }

        vm.warp(block.timestamp + donations.getInterval() + 1);
        (bool upkeepNeeded, ) = donations.checkUpkeep("");
        assertTrue(upkeepNeeded);

        vm.recordLogs();
        donations.performUpkeep("");

        Vm.Log[] memory entries_performUpkeep = vm.getRecordedLogs();

        uint256 requestId = uint256(entries_performUpkeep[1].topics[1]);

        console2.log("Request ID: ", requestId);
        console2.log("Donating State: ", uint256(donations.getDonationStatus()));
        console2.log("Donors Length: ", donations.getDonorsCount());
        console2.log("Recent Winner: ", donations.getRecentWinner());
        console2.log("Starting Time Stamp: ", donations.getLastTimeStamp());

        vm.recordLogs();
        VRFCoordinatorV2_5Mock(vrfCoordinator).fulfillRandomWords(requestId, address(donations));

        Vm.Log[] memory entries_fulFillRandomWords = vm.getRecordedLogs();


        console2.log("=====================================");
        console2.log("Request ID: ", requestId);
        console2.log("Donating State: ", uint256(donations.getDonationStatus()));
        console2.log("Donors Length: ", donations.getDonorsCount());
        console2.log("Recent Winner: ", donations.getRecentWinner());
        console2.log("Last Time Stamp: ", donations.getLastTimeStamp());

        assertEq(uint256(donations.getDonationStatus()), uint256(Donations.DonationStatus.OPEN));
        assertEq(donations.getGiftNFT().getLatestTokenId(), 1);
        assertEq(donations.getGiftNFT().balanceOf(donations.getRecentWinner()), 1);
        assertEq(donations.getGiftNFT().ownerOf(donations.getGiftNFT().getLatestTokenId()), donations.getRecentWinner());

    }

    /*//////////////////////////////////////////////////////////////
                         TEST VRF INTERACTIONS
    //////////////////////////////////////////////////////////////*/

    function testCreateSubscription() external onlyLocal {
        CreateSubscription createSub = new CreateSubscription();
        (uint256 subId, ) = createSub.createSubscription(vrfCoordinator, FOUNDRY_DEFAULT_SENDER);
        
        assert(subId != 0);
    }

    function testFundSubscription() external onlyLocal {
        CreateSubscription createSub = new CreateSubscription();
        (uint256 subId, ) = createSub.createSubscription(vrfCoordinator, FOUNDRY_DEFAULT_SENDER);

        FundSubscription fundSub = new FundSubscription();
        fundSub.fundSubscription(subId, vrfCoordinator, FOUNDRY_DEFAULT_SENDER, helperConfig.getConfig().linkToken);

        assertEq(VRFCoordinatorV2_5Mock(vrfCoordinator).getSubscriptionBalance(subId), FUND_AMOUNT);

    }

    function testAddConsumer() external onlyLocal {

        CreateSubscription createSub = new CreateSubscription();
        (uint256 subId, ) = createSub.createSubscription(vrfCoordinator, FOUNDRY_DEFAULT_SENDER);

        FundSubscription fundSub = new FundSubscription();
        fundSub.fundSubscription(subId, vrfCoordinator, FOUNDRY_DEFAULT_SENDER, helperConfig.getConfig().linkToken);

        AddConsumer addConsumer = new AddConsumer();
        addConsumer.addConsumer(address(donations), vrfCoordinator, subId, FOUNDRY_DEFAULT_SENDER);

        assertEq(VRFCoordinatorV2_5Mock(vrfCoordinator).consumerIsAdded(subId, address(donations)), true);

    }

}
