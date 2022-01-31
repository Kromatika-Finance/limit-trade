// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.7.6;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/SafeCast.sol";
import "@openzeppelin/contracts-upgradeable/proxy/Initializable.sol";

import "@uniswap/v3-periphery/contracts/libraries/PoolAddress.sol";
import "@uniswap/v3-periphery/contracts/libraries/OracleLibrary.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";

import "./interfaces/IUniswapUtils.sol";

// use library ?
contract UniswapUtils is IUniswapUtils, Initializable {

    using SafeMath for uint256;
    using SafeCast for uint256;

    uint24 public constant POOL_FEE = 3000;

    address public controller;

    uint32 public twapPeriod;

    /// @dev when controller has changed
    event ControllerChanged(address from, address newValue);

    /// @dev when twap was changed
    event TwapPeriodChanged(address from, uint32 newValue);

    constructor () initializer {}

    function initialize() public initializer {
        controller = msg.sender;
        twapPeriod = 1800;
    }

    function calculateLimitTicks(
        IUniswapV3Pool _pool,
        uint160 _sqrtPriceX96,
        uint256 _amount0,
        uint256 _amount1
    ) external override view
    returns (
        int24 _lowerTick,
        int24 _upperTick,
        uint128 _liquidity,
        uint128 _orderType
    ) {

        int24 tickSpacing = _pool.tickSpacing();
        (uint160 sqrtRatioX96,, , , , , ) = _pool.slot0();

        int24 _targetTick = TickMath.getTickAtSqrtRatio(_sqrtPriceX96);

        int24 tickFloor = _floor(_targetTick, tickSpacing);

        return _checkLiquidityRange(
            tickFloor - tickSpacing,
            tickFloor,
            tickFloor,
            tickFloor + tickSpacing,
            _amount0,
            _amount1,
            sqrtRatioX96,
            tickSpacing
        );

    }

    function quoteKROM(IUniswapV3Factory factory, address WETH, address KROM, uint256 _weiAmount)
    external override view returns (uint256 quote) {

        address _poolAddress = factory.getPool(WETH, KROM, POOL_FEE);
        require(_poolAddress != address(0), "UUC_PA");

        if (_weiAmount > 0) {
            int24 arithmeticMeanTick = _getMeanTickTwap(_poolAddress, twapPeriod);
            quote = OracleLibrary.getQuoteAtTick(
                arithmeticMeanTick,
                _weiAmount.toUint128(),
                WETH,
                KROM
            );
        }
    }

    function _getMeanTickTwap(address _poolAddress, uint32 twapInterval) internal view returns (
        int24 arithmeticMeanTick
    ) {

        if (twapInterval == 0) {
            // return the current price if twapInterval == 0
            (,arithmeticMeanTick, , , , , ) = IUniswapV3Pool(_poolAddress).slot0();
        } else {
            uint32[] memory secondsAgos = new uint32[](2);
            secondsAgos[0] = twapInterval;
            secondsAgos[1] = 0;

            (int56[] memory tickCumulatives,) = IUniswapV3Pool(_poolAddress).observe(secondsAgos);

            int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];
            arithmeticMeanTick = int24(tickCumulativesDelta / twapInterval);
            // Always round to negative infinity
            if (tickCumulativesDelta < 0 && (tickCumulativesDelta % twapInterval != 0)) arithmeticMeanTick--;
        }
    }

    function changeController(address _controller) external {

        isAuthorizedController();
        controller = _controller;
        emit ControllerChanged(msg.sender, _controller);
    }

    function changeTwapPeriod(uint32 _twapPeriod) external {

        isAuthorizedController();
        twapPeriod = _twapPeriod;
        emit TwapPeriodChanged(msg.sender, _twapPeriod);
    }

    function _checkLiquidityRange(int24 _bidLower, int24 _bidUpper,
        int24 _askLower, int24 _askUpper,
        uint256 _amount0, uint256 _amount1,
        uint160 sqrtRatioX96, int24 _tickSpacing) internal pure
    returns (int24 _lowerTick, int24 _upperTick, uint128 _liquidity, uint128 _orderType) {

        _checkRange(_bidLower, _bidUpper, _tickSpacing);
        _checkRange(_askLower, _askUpper, _tickSpacing);

        uint128 bidLiquidity = _liquidityForAmounts(sqrtRatioX96, _bidLower, _bidUpper, _amount0, _amount1);
        uint128 askLiquidity = _liquidityForAmounts(sqrtRatioX96, _askLower, _askUpper, _amount0, _amount1);

        require(bidLiquidity > 0 || askLiquidity > 0, "UUC_BAL");

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
    ) external override view returns (uint256, uint256) {
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

        require(_tickLower < _tickUpper, "UUC_TLU");
        require(_tickLower >= TickMath.MIN_TICK, "UUC_TLMIN");
        require(_tickUpper <= TickMath.MAX_TICK, "UUC_TAMAX");
        require(_tickLower % _tickSpacing == 0, "UUC_TLS");
        require(_tickUpper % _tickSpacing == 0, "UUC_TUS");
    }

    function isAuthorizedController() internal view {
        require(msg.sender == controller, "UUC_AC");
    }

    /// @dev Rounds tick down towards negative infinity so that it's a multiple
    /// of `tickSpacing`.
    function _floor(int24 tick, int24 _tickSpacing) internal pure returns (int24) {
        int24 compressed = tick / _tickSpacing;
        if (tick < 0 && tick % _tickSpacing != 0) compressed--;
        return compressed * _tickSpacing;
    }

    receive() external payable {}
}