//SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

/**
 * @title  Gift NFT Contract For Charity Donations
 * @author  Mossad ElMahgob
 * @notice  This contract allows charity organizations to mint a gift NFT for a donor after making a donation to the charity.
 */

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract GiftNFT is ERC721, Ownable {
    uint256 private s_tokenCounter;

    constructor() ERC721("GiftNFT", "GNFT") Ownable() {
        s_tokenCounter = 1;
    }

    function mintGiftNFT(address recipient) external onlyOwner {
        _safeMint(recipient, s_tokenCounter);
        s_tokenCounter++;
    }

    function getLatestTokenId() external view returns (uint256) {
        return s_tokenCounter - 1;
    }
}
