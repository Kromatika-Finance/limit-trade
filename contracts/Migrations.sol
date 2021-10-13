// SPDX-License-Identifier: MIT

pragma solidity >=0.4.22 <0.9.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

contract Migrations {
  address public owner = msg.sender;
  // solhint-disable-next-line
  uint public last_completed_migration;

  modifier restricted() {
    require(msg.sender == owner, "This function is restricted to the contract's owner");
    _;
  }

  function setCompleted(uint completed) public restricted {
    last_completed_migration = completed;
  }
}
