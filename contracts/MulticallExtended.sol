// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.7.6;
pragma abicoder v2;

import "./Multicall.sol";

/// @title MulticallExtended
/// @notice Enables calling multiple methods in a single call to the contract
abstract contract MulticallExtended is Multicall {

    function multicall(uint256 deadline, bytes[] calldata data)
    external
    payable
    returns (bytes[] memory)
    {
        require(block.timestamp <= deadline, 'OLD');
        return multicall(data);
    }
}