//SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

interface IListaBNBStakeManager {
    function deposit() external payable;
    
    function convertBnbToSnBnb(uint256 _amount) external view returns (uint256);

    function convertSnBnbToBnb(uint256 _amountInSlisBnb) external view returns (uint256);
}