// SPDX-License-Identifier: MIT

pragma solidity >=0.7.5;

interface IOrderMonitor {

    function batchPayment(uint256 batchId) external view returns (uint256 payment);

    function startMonitor(uint256 _tokenId) external;

    function stopMonitor(uint256 _tokenId) external;

}