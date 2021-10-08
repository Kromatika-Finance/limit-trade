// SPDX-License-Identifier: MIT

pragma solidity >=0.7.5;

interface ILimitTradeManager {

    function closeLimitTrade(
        uint256 _tokenId
    ) external returns (uint256, uint256);

}