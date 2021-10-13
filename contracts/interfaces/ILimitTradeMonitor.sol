// SPDX-License-Identifier: MIT

pragma solidity >=0.7.5;

interface ILimitTradeMonitor {

    function batchInfo(uint256 batchId) external view returns (uint256 payment, address creator);

    function startMonitor(
        uint256 _tokenId, uint256 _amount0, uint256 _amount1
    ) external;

    function stopMonitor(uint256 _tokenId) external;

}