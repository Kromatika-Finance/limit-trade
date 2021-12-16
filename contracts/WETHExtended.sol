// SPDX-License-Identifier: MIT

pragma solidity >=0.7.5;

import "@uniswap/v3-periphery/contracts/interfaces/external/IWETH9.sol";
import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";

contract WETHExtended {

    function withdraw(uint wad, address _beneficiary, IWETH9 WETH) public {

        WETH.withdraw(wad);
        TransferHelper.safeTransferETH(_beneficiary, wad);
    }

    receive() external payable {}
}