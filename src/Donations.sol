//SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

/**
 * @title Charity Donations Collecting
 * @author Mossad ElMahgob
 * @notice Primary contract that collects ETH donations, forwards funds to a configured
 *         charity wallet, tracks donors and donation amounts, and periodically selects
 *         a random donor to receive a Gift NFT using Chainlink VRF.
 * @dev Designed to be testable with Foundry/Anvil (uses a VRF coordinator mock) and
 *      integrates with a lightweight ERC721 `GiftNFT` contract to mint prizes.
 */


/*//////////////////////////////////////////////////////////////
                        IMPORTS
//////////////////////////////////////////////////////////////*/
import {console2} from "forge-std/console2.sol";
import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {GiftNFT} from "./GiftNFT.sol";
import {AutomationCompatibleInterface} from "@chainlink/contracts/src/v0.8/interfaces/AutomationCompatibleInterface.sol";

/*//////////////////////////////////////////////////////////////
                         ERRORS
//////////////////////////////////////////////////////////////*/
error Donations_DonationMustBeGreaterThanZero();
error Donations_TransferMoneyToCharityFailed();
error Donations_DonationIsPending();
error Donations_DonationIsOpenCannotPickAWinner();
error Donations_UpkeepNotNeeded(uint256 donorsCount, uint256 donationState, uint256 interval);
error Donations_OnlyOwnerCanSetDonationStatus();
error Donations_OnlyOwnerCanChangeCharityWallet();
/*//////////////////////////////////////////////////////////////
                INTERFACES, LIBRARIES, CONTRACTS
//////////////////////////////////////////////////////////////*/
contract Donations is VRFConsumerBaseV2Plus {

    /*//////////////////////////////////////////////////////////////
                        TYPE DECLARATIONS
    //////////////////////////////////////////////////////////////*/
    /**
     * @dev Enum to represent the status of the donation process.
     * OPEN: Donations are being collected.
     * PENDING: A winner is being picked.
     */
    enum DonationStatus {
        OPEN,
        PENDING
    }
    /*//////////////////////////////////////////////////////////////
                        STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    /// @notice Number of confirmations the VRF request needs
    uint16 private constant REQUEST_CONFIRMATIONS = 3;

    /// @notice How many random words we expect (1 is enough to pick a single winner)
    uint32 private constant NUM_WORDS = 1;

    /// @notice List of donor addresses (reset after each winner selection)
    address payable[] private s_donors;

    /// @notice Tracks the donation amount for each donor in the current round
    mapping(address => uint256) private s_donorsToAmount;

    /// @notice Contract deployer / admin
    address private immutable s_owner;

    /// @notice Charity wallet that receives forwarded donations
    address payable private s_charityWallet;

    /// @notice Current donation process status (OPEN or PENDING)
    DonationStatus donationStatus;

    /// @notice Interval (seconds) between winner selections
    uint256 private immutable i_interval;

    /// @notice Timestamp for the last winner selection or last donation forward
    uint256 private s_lastTimeStamp;

    /// @notice Chainlink VRF key hash / gas lane
    bytes32 private immutable i_keyHash;

    /// @notice Chainlink VRF subscription id
    uint256 private immutable i_subId;

    /// @notice Callback gas limit for VRF fulfill function
    uint32 private immutable i_callBackGasLimit;

    /// @notice Last selected winner (receives the NFT prize)
    address payable private s_recentWinner;

    /// @notice The NFT contract used to mint prizes to winners
    GiftNFT private giftNFT;

    /// @notice Cumulative donated amount per donor across all rounds (optional analytics)
    mapping(address => uint256) private s_donorsToTheAllDonatedMoney;

    /*//////////////////////////////////////////////////////////////
                            EVENTS
    //////////////////////////////////////////////////////////////*/
    /// @notice Emitted when a non-zero coordinator address is provided at construction
    event Donations_VrfCoordinatorWasCorrectlySet(address indexed vrfCoordinator);

    /// @notice Emitted when a donation is received
    event Donations_DonationReceived(address indexed donor, uint256 amount);

    /// @notice Emitted when the charity wallet address is changed or funds forwarded
    event Donations_CharityWalletUpdated(address indexed newCharityWallet);

    /// @notice Emitted when a new donor is added to the current donor list
    event Donations_DonorAdded(address indexed donor, uint256 amount);

    /// @notice Emitted when an existing donor contributes additional funds
    event Donations_DonorIsFoundAddingNewFunds(address indexed donor, uint256 amount);

    /// @notice Emitted when a VRF randomness request is created
    event Donations_VrfRequestCreated(uint256 indexed requestId);

    /// @notice Emitted when a winner is selected
    event Donations_WinnerPicked(address indexed winner);

    /// @notice Emitted when an NFT is minted and transferred to the recent winner
    event Donations_NFTGiftedForTheRecentWinner(address indexed winner, uint256 tokenId);

    /*//////////////////////////////////////////////////////////////
                            MODIFIERS
    //////////////////////////////////////////////////////////////*/


    /*//////////////////////////////////////////////////////////////
                            FUNCTIONS
    //////////////////////////////////////////////////////////////*/


    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice Construct the Donations contract
     * @param subId Chainlink VRF subscription id (set to 0 for local testing mocks)
     * @param vrfCoordinator Address of the Chainlink VRF Coordinator
     * @param gasLane Key hash / gas lane used by the VRF subscription
     * @param callbackGasLimit Gas limit passed to the VRF callback
     * @param interval Time interval (seconds) between winner selections
     */
    constructor(
    uint256 subId,
    address vrfCoordinator,
    bytes32 gasLane,
    uint32 callbackGasLimit,
    uint256 interval
    ) VRFConsumerBaseV2Plus(vrfCoordinator){
        // Set immutable owner and default charity receiver to deployer
        s_owner = msg.sender;
        s_charityWallet = payable(msg.sender);

        // VRF / timing configuration
        i_subId = subId;
        i_keyHash = gasLane;
        i_callBackGasLimit = callbackGasLimit;
        donationStatus = DonationStatus.OPEN;
        i_interval = interval;
        s_lastTimeStamp = block.timestamp;

        // Deploy a fresh GiftNFT instance for awarding winners
        giftNFT = new GiftNFT();

        // Emit a helpful event when VRF coordinator is explicitly provided
        if(vrfCoordinator != address(0)) {
            emit Donations_VrfCoordinatorWasCorrectlySet(vrfCoordinator);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        RECEIVE FUNCTION
    //////////////////////////////////////////////////////////////*/

    receive() external payable {
        emit Donations_DonationReceived(msg.sender, msg.value);
    }

    /*//////////////////////////////////////////////////////////////
                        FALLBACK FUNCTION
    //////////////////////////////////////////////////////////////*/


    /*//////////////////////////////////////////////////////////////
                            EXTERNAL
    //////////////////////////////////////////////////////////////*/

    function getDonors(uint256 index) external view returns (address) {
        // Function to get the address of a donor at a specific index.
        return s_donors[index];
    }

    function getDonorsToAmount(address donor) external view returns (uint256) {
        // Function to get the donation amount of a specific donor.
        return s_donorsToAmount[donor];
    }

    function getCharityWallet() external view returns (address) {
        // Function to get the address of the charity wallet.
        return s_charityWallet;
    }

    function getOwner() external view returns (address) {
        // Function to get the address of the contract owner.
        return s_owner;
    }

    function getDonorsCount() external view returns (uint256) {
        // Function to get the total number of donors.
        return s_donors.length;
    }

    function getDonationStatus() external view returns (uint256) {
        return uint256(donationStatus);
    }

    function getInterval() external view returns (uint256) {
        // Function to get the interval for picking a winner.
        return i_interval;
    }

    function getRecentWinner() external view returns (address) {
        return s_recentWinner;
    }

    function getGiftNFT() external view returns (GiftNFT) {
        // Function to get the GiftNFT contract instance.
        return giftNFT;
    }

    function getLastTimeStamp() external view returns (uint256) {
        // Function to get the last time a winner was picked.
        return s_lastTimeStamp;
    }

    function getAllDonatedMoney(address donor) external view returns (uint256) {
        return s_donorsToTheAllDonatedMoney[donor];
    }

    /*//////////////////////////////////////////////////////////////
                            PUBLIC
    //////////////////////////////////////////////////////////////*/    

    function donate() public payable {
        /**
         * @notice Donate ETH to the charity. The amount is immediately forwarded to the
         *         configured charity wallet. Donor and amount are tracked for the current
         *         round used by the random winner selection logic.
         * @dev Emits Donations_DonationReceived and Donations_CharityWalletUpdated (on success).
         */
        console2.log("Donating to charity...");

        // Basic validation
        if(msg.value <= 0){
            console2.log("Donation must be greater than zero");
            revert Donations_DonationMustBeGreaterThanZero();
        }

        // Prevent donations while a winner is being picked
        if(uint256(donationStatus) == uint256(DonationStatus.PENDING)) {
            console2.log("Donating Is Not Availabile Right Now.");
            revert Donations_DonationIsPending();
        }

        console2.log("Amount (ether):", msg.value / 1e18);
        uint256 donationAmount = msg.value;
        address donor = msg.sender;

        // Track new donor or additional donation amount
        if(s_donorsToAmount[donor] == 0){
            s_donors.push(payable(donor));
            console2.log("New donor added:", donor);
            emit Donations_DonorAdded(donor, donationAmount);
        }
        if(s_donorsToAmount[donor] != 0)
        {
            emit Donations_DonorIsFoundAddingNewFunds(donor, donationAmount);
        }

        // Update accounting
        s_donorsToAmount[donor] += donationAmount;
        s_donorsToTheAllDonatedMoney[donor] += donationAmount;
        emit Donations_DonationReceived(donor, donationAmount);
        console2.log("Total donated by", donor, ":", s_donorsToAmount[donor]);

        // Forward funds to the charity wallet using .call and handle failure
        console2.log("Donation successful, transferring funds to charity wallet:", s_charityWallet);
        (bool success, ) = s_charityWallet.call{value: donationAmount}("");
        if(!success){
            console2.log("Transfer to charity wallet failed");
            revert Donations_TransferMoneyToCharityFailed();
        }

        // Update last timestamp and notify observers
        s_lastTimeStamp = block.timestamp;
        console2.log("Funds transferred successfully");
        emit Donations_CharityWalletUpdated(s_charityWallet);
    }

    // @dev Next Logic Is For Picking A Random Donor 
    // To Give Him A Gift And Automating This process 
    // Each Time There Is Donors.

    /**
     * @notice Picks a random donor and sends them a gift (only callable by owner).
     */

    /**
     * @notice Called to trigger the off-chain/Chainlink VRF flow when upkeep conditions are met.
     * @dev This function checks `checkUpkeep` and then requests random words from the VRF coordinator.
     *      It sets the donationStatus to PENDING to prevent concurrent donations during selection.
     * @return requestId The Chainlink VRF request id.
     */
    function performUpkeep(bytes calldata) external returns(uint256 requestId) {
        (bool upKeepNeeded, ) = checkUpkeep("");
        if(!upKeepNeeded) {
            revert Donations_UpkeepNotNeeded(s_donors.length, uint256(donationStatus), i_interval);
        }

        // Prevent additional donations while we wait for VRF
        donationStatus = DonationStatus.PENDING;

        // Build and send VRF request using the VRFConsumerBaseV2Plus helper
    requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest(
                {
                    keyHash: i_keyHash,
                    subId: i_subId,
                    requestConfirmations: REQUEST_CONFIRMATIONS,
                    callbackGasLimit: i_callBackGasLimit,
                    numWords: NUM_WORDS,
                    extraArgs: VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: false}))
                }
            )
        );
        emit Donations_VrfRequestCreated(requestId);
        return requestId;
    }

    function setDonationStatus(DonationStatus status) external {
        // Function to set the donation status (only callable by owner).
        if(msg.sender != s_owner) {
            revert Donations_OnlyOwnerCanSetDonationStatus();
        }
        donationStatus = status;
    }

    function changeCharityWallet(address newCharityWallet) external {
        // Function to change the charity wallet (only callable by owner).
        if(msg.sender != s_owner) {
            revert Donations_OnlyOwnerCanChangeCharityWallet();
        }
        s_charityWallet = payable(newCharityWallet);
        emit Donations_CharityWalletUpdated(newCharityWallet);
    }

    /*//////////////////////////////////////////////////////////////                        
                            INTERNAL
    //////////////////////////////////////////////////////////////*/

    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) internal override {
        // VRF callback: pick a random winner and award the NFT
        console2.log("Random Words Fulfilled:");
        // Log the requestId to avoid unused-parameter warnings and aid debugging
        console2.log("VRF requestId:", requestId);

        // Use modulo to select a winner from the current donors list
        uint256 winnerIndex = randomWords[0] % s_donors.length;
        address payable recentWinner = s_donors[winnerIndex];
        s_recentWinner = recentWinner;
        console2.log("Winner is:", recentWinner);

        // Reset state so donations can resume
        donationStatus = DonationStatus.OPEN;
        s_lastTimeStamp = block.timestamp;

        // Reset donors balances for the next round
        uint256 s_donorsCount = s_donors.length;
        for (uint256 i = 0; i < s_donorsCount; i++) {
            s_donorsToAmount[s_donors[i]] = 0;
        }

        // Clear the donors array
        s_donors = new address payable[](0);
        emit Donations_WinnerPicked(recentWinner);
        console2.log("Winner picked, transferring gift NFT to winner...");

        // Mint and transfer the prize NFT to the winner
        giftNFT.mintGiftNFT(recentWinner);
        emit Donations_NFTGiftedForTheRecentWinner(recentWinner, giftNFT.getLatestTokenId());
    }

    /*//////////////////////////////////////////////////////////////
                            PRIVATE
    //////////////////////////////////////////////////////////////*/


    /*//////////////////////////////////////////////////////////////
                        VIEW AND PURE 
    //////////////////////////////////////////////////////////////*/

    function checkUpkeep(bytes memory /* checkData */)
        public
        view
        returns (bool upkeepNeeded, bytes memory /* performData */)
    {
        bool intervalHasPassed = (block.timestamp - s_lastTimeStamp) >= i_interval;
        console2.log("Interval has passed:", intervalHasPassed);
        bool thereIsDonors = s_donors.length > 0;
        console2.log("There are donors:", thereIsDonors);
        bool isOpen = donationStatus == DonationStatus.OPEN;
        console2.log("Donation is open:", isOpen);
        upkeepNeeded = intervalHasPassed && thereIsDonors && isOpen;
        return (upkeepNeeded, "");
    }


}
