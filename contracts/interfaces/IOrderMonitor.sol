// SPDX-License-Identifier: MIT

pragma solidity >=0.7.5;

interface IOrderMonitor {

    function batchInfo(uint256 batchId) external view returns (uint256 payment, address creator);

    function startMonitor(
        uint256 _tokenId, uint256 _amount0, uint256 _amount1, uint256 _targetGasPrice
    ) external;

    function stopMonitor(uint256 _tokenId) external;

}