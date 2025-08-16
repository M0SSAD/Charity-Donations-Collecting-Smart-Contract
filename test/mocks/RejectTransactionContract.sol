//SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

contract RejectTransactionContract {
    receive() external payable {
        revert("Transaction rejected");
    }

    fallback() external payable {
        revert("Transaction rejected");
    }
}