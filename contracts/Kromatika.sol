// SPDX-License-Identifier: MIT

pragma solidity >=0.7.5;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

///	@title	Kromatika token contract
contract Kromatika is ERC20 {

    constructor() ERC20("Kromatika", "KROM") {
        _mint(msg.sender, 100000000 * 10 ** decimals());
    }
}