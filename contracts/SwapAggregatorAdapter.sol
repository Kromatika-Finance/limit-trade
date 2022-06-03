// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.7.6;
pragma abicoder v2;

import "@openzeppelin/contracts/utils/Address.sol";
import "./interfaces/IAdapter.sol";

import "./LibERC20Adapter.sol";

contract SwapAggregatorAdapter is IAdapter {

    using Address for address;

    /// @dev swap adapter data
    struct SwapAggregatorData {
        IERC20 tokenFrom;
        IERC20 tokenTo;
        uint256 amountFrom;
        address aggregator;
        bytes aggregatorData;
    }

    function adapt(AdapterContext calldata context)
    external
    payable
    override
    returns (bytes4 success)
    {
        SwapAggregatorData memory data = abi.decode(context.data, (SwapAggregatorData));

        // 1. check allowance and approve (even for WETH)
        if (!LibERC20Adapter.isTokenETH(data.tokenFrom)) {
            //tokenFrom.safeTransferFrom(recipient, address(this), amountFrom);
            TransferHelper.safeApprove(address(data.tokenFrom), data.aggregator, data.amountFrom);
        }

        // 2. call the aggregator with aggregator data
        data.aggregator.functionCallWithValue(data.aggregatorData, msg.value);

        // 3. Transfer remaining balance of tokenTo to recipient
        _transfer(data.tokenTo, context.recipient);

        // 4. Transfer remaining balance of tokenFrom back to the sender
        _transfer(data.tokenFrom, context.sender);

        return LibERC20Adapter.TRANSFORMER_SUCCESS;
    }

    function _transfer(IERC20 tokenToTransfer, address payable recipient) internal {

        uint256 amountOut = LibERC20Adapter.getTokenBalanceOf(tokenToTransfer, address(this));
        if (amountOut > 0) {
            LibERC20Adapter.adapterTransfer(tokenToTransfer, recipient, amountOut);
        }
    }
}
