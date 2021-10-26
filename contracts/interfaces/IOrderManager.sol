// SPDX-License-Identifier: MIT

pragma solidity >=0.7.5;

interface IOrderManager {

    function closeOrder(
        uint256 _tokenId, uint256 _batchId
    ) external returns (uint256, uint256);

    function funding(address owner) external view returns (uint256 balance);

    function estimateServiceFee(uint256 _targetGasPrice) external returns (uint256);
}