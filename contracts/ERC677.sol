// SPDX-License-Identifier: MIT

pragma solidity >=0.7.5;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "./interfaces/IERC677Receiver.sol";

abstract contract ERC677 is ERC20 {
    event Transfer(address indexed from, address indexed to, uint value, bytes data);

    modifier validRecipient(address _recipient) {
        require(_recipient != address(0) && _recipient != address(this));
        _;
    }

    function transferAndCall(address _to, uint _value, bytes calldata _data)
    external validRecipient(_to) returns (bool) {
        require(transfer(_to, _value));
        emit Transfer(msg.sender, _to, _value, _data);
        if (Address.isContract(_to)) {
            contractFallback(_to, _value, _data);
        }
        return true;
    }

    function contractFallback(address _to, uint _value, bytes calldata _data)
    private {
        IERC677Receiver receiver = IERC677Receiver(_to);
        receiver.onTokenTransfer(msg.sender, _value, _data);
    }
}