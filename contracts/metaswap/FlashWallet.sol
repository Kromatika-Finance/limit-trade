// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.7.6;
pragma abicoder v2;

import "../interfaces/IFlashWallet.sol";

contract FlashWallet is IFlashWallet {

    address public override immutable owner;

    constructor() public {
        // The deployer is the owner.
        owner = msg.sender;
    }

    modifier onlyOwner() virtual {
        require(msg.sender == owner, "FW_NA");
        _;
    }

    function executeDelegateCall(
        address payable target,
        bytes calldata callData
    )
    external
    payable
    override
    onlyOwner
    returns (bytes memory resultData)
    {
        bool success;
        (success, resultData) = target.delegatecall(callData);
        if (!success) {
            revert(abi.decode(resultData, (string)));
        }
    }

    /// @dev Receives ether from swaps
    receive() external override payable {}
}