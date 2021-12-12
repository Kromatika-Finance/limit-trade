// SPDX-License-Identifier: MIT

pragma solidity >=0.7.5;
pragma abicoder v2;

import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v3-periphery/contracts/interfaces/external/IWETH9.sol";

import "./LimitOrderMonitor.sol";
import "./WETHExtended.sol";

/// @title  LimitOrderMonitorETH
contract LimitOrderMonitorETH is LimitOrderMonitor {

    uint24 public constant POOL_FEE = 3000;

    /// @dev swap router
    ISwapRouter public swapRouter;

    /// @dev wrapper ETH
    IWETH9 public WETH;

    /// @dev simple WETH adapter
    WETHExtended public WETHExt;

    function initialize(IOrderManager _orderManager,
        IUniswapV3Factory _factory,
        IERC20 _KROM,
        uint24 _batchSize,
        uint24 _monitorSize,
        uint24 _upkeepInterval,
        uint24 _monitorFee,
        ISwapRouter _swapRouter,
        IWETH9 _WETH,
        WETHExtended _WETHExt
    ) public initializer {

        super.initialize(
            _orderManager, _factory, _KROM, _batchSize, _monitorSize, _upkeepInterval, _monitorFee
        );

        swapRouter = _swapRouter;
        WETH = _WETH;
        WETHExt = _WETHExt;
    }

    function _transferFees(uint256 _amount, address _owner) internal virtual override  {

        if (_amount > 0) {
            // swap KROM into ETH
            TransferHelper.safeApprove(address(KROM), address(swapRouter), _amount);

            ISwapRouter.ExactInputSingleParams memory params =
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(KROM),
                tokenOut: address(WETH),
                fee: POOL_FEE,
                recipient: address(WETHExt),
                deadline: block.timestamp,
                amountIn: _amount,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });

            // swap and send
            _amount = swapRouter.exactInputSingle(params);

            WETHExt.withdraw(_amount, _owner, WETH);
        }
    }
}