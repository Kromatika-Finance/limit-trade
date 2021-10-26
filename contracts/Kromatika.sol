// SPDX-License-Identifier: MIT

pragma solidity >=0.7.5;

import "./ERC677.sol";
import "./interfaces/IERC677Receiver.sol";

///	@title	Kromatika token contract
contract Kromatika is ERC677 {

    constructor() ERC20("Kromatika", "KROM") {
        _mint(msg.sender, 1000000000 * 10 ** decimals());
    }
}