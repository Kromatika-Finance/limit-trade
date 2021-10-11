// SPDX-License-Identifier: MIT

pragma solidity >=0.7.5;

interface ILimitSignalKeeper {

    function batchInfo(uint256 batchId) external view returns (uint256 count, uint256 gasCost);

    function startMonitor(
        uint256 _tokenId, uint256 _amount0, uint256 _amount1
    ) external;

}