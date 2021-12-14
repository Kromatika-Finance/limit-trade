// SPDX-License-Identifier: MIT

pragma solidity >=0.7.5;

interface IOrderMonitor {

    function startMonitor(uint256 _tokenId) external;

    function stopMonitor(uint256 _tokenId) external;

}