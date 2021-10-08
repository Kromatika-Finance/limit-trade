// SPDX-License-Identifier: MIT

pragma solidity >=0.7.5;

interface ILimitSignalKeeper {

    function startMonitor(
        uint256 _tokenId, uint256 _amount0, uint256 _amount1
    ) external;

}