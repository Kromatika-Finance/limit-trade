// SPDX-License-Identifier: MIT

pragma solidity >=0.7.5;
pragma abicoder v2;

interface IOrderManager {

    struct LimitOrderParams {
        address _token0; 
        address _token1; 
        uint24 _fee;
        uint160 _sqrtPriceX96;
        uint256 _amount0;
        uint256 _amount1; 
        uint256 _targetGasPrice;
    }

    function placeLimitOrder(LimitOrderParams calldata params) external payable returns (uint256 tokenId);

    function processLimitOrder(
        uint256 _tokenId, uint256 _batchId
    ) external returns (uint256, uint256, uint256);

    function canProcess(uint256 _tokenId, uint256 gasPrice) external view returns (bool);

    function quoteKROM(uint256 weiAmount) external view returns (uint256 quote);

    function funding(address owner) external view returns (uint256 balance);
}