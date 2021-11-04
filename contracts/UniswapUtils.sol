// SPDX-License-Identifier: MIT

pragma solidity >=0.7.5;
pragma abicoder v2;

import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";
import "@uniswap/v3-periphery/contracts/libraries/PoolAddress.sol";
import "@uniswap/v3-periphery/contracts/libraries/OracleLibrary.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3MintCallback.sol";
import "@uniswap/v3-periphery/contracts/libraries/PositionKey.sol";
import "@uniswap/v3-periphery/contracts/libraries/CallbackValidation.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";
import "./interfaces/IOrderManager.sol";

library UniswapUtils {

    function calculateLimitTicks(
        IUniswapV3Pool _pool, IOrderManager.LimitOrderParams memory params) external view
    returns (
        int24 _lowerTick,
        int24 _upperTick,
        uint128 _liquidity,
        uint128 _orderType
    ) {

        int24 tickSpacing = _pool.tickSpacing();
        (uint160 sqrtRatioX96,, , , , , ) = _pool.slot0();

        int24 _targetTick = TickMath.getTickAtSqrtRatio(params._sqrtPriceX96);

        int24 tickFloor = _floor(_targetTick, tickSpacing);
        int24 tickCeil = tickFloor + tickSpacing;

        return _checkLiquidityRange(
            tickFloor - tickSpacing, 
            tickFloor,
            tickCeil, 
            tickCeil + tickSpacing,
            params._amount0,
            params._amount1,
            sqrtRatioX96, 
            tickSpacing
        );

    }

    function _checkLiquidityRange(int24 _bidLower, int24 _bidUpper,
        int24 _askLower, int24 _askUpper,
        uint256 _amount0, uint256 _amount1,
        uint160 sqrtRatioX96, int24 _tickSpacing) internal view
    returns (int24 _lowerTick, int24 _upperTick, uint128 _liquidity, uint128 _orderType) {

        _checkRange(_bidLower, _bidUpper, _tickSpacing);
        _checkRange(_askLower, _askUpper, _tickSpacing);

        uint128 bidLiquidity = _liquidityForAmounts(sqrtRatioX96, _bidLower, _bidUpper, _amount0, _amount1);
        uint128 askLiquidity = _liquidityForAmounts(sqrtRatioX96, _askLower, _askUpper, _amount0, _amount1);

        require(bidLiquidity > 0 || askLiquidity > 0);

        if (bidLiquidity > askLiquidity) {
            (_lowerTick, _upperTick, _liquidity, _orderType) = (_bidLower, _bidUpper, bidLiquidity, uint128(1));
        } else {
            (_lowerTick, _upperTick, _liquidity, _orderType) = (_askLower, _askUpper, askLiquidity, uint128(2));
        }
    }

    /// @dev Wrapper around `LiquidityAmounts.getLiquidityForAmounts()`.
    function _liquidityForAmounts(
        uint160 sqrtRatioX96,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128) {
        return
        LiquidityAmounts.getLiquidityForAmounts(
            sqrtRatioX96,
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper),
            amount0,
            amount1
        );
    }

    /// @dev Wrapper around `LiquidityAmounts.getAmountsForLiquidity()`.
    function _amountsForLiquidity(
        IUniswapV3Pool pool,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) external view returns (uint256, uint256) {
        (uint160 sqrtRatioX96, , , , , , ) = pool.slot0();
        return
        LiquidityAmounts.getAmountsForLiquidity(
            sqrtRatioX96,
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper),
            liquidity
        );
    }

    function _checkRange(int24 _tickLower, int24 _tickUpper, int24 _tickSpacing) internal pure {

        require(_tickLower < _tickUpper);
        require(_tickLower >= TickMath.MIN_TICK);
        require(_tickUpper <= TickMath.MAX_TICK);
        require(_tickLower % _tickSpacing == 0);
        require(_tickUpper % _tickSpacing == 0);
    }

    /// @dev Rounds tick down towards negative infinity so that it's a multiple
    /// of `tickSpacing`.
    function _floor(int24 tick, int24 _tickSpacing) internal pure returns (int24) {
        int24 compressed = tick / _tickSpacing;
        if (tick < 0 && tick % _tickSpacing != 0) compressed--;
        return compressed * _tickSpacing;
    }
}