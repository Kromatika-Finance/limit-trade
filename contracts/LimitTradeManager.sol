// SPDX-License-Identifier: MIT

pragma solidity >=0.7.5;
pragma abicoder v2;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import '@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol';
import "@openzeppelin/contracts/access/Ownable.sol";

import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";
import "@uniswap/v3-periphery/contracts/libraries/PoolAddress.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3MintCallback.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";
import "@uniswap/v3-periphery/contracts/libraries/PositionKey.sol";

import "@uniswap/v3-periphery/contracts/interfaces/external/IWETH9.sol";
import "@uniswap/v3-periphery/contracts/interfaces/IQuoterV2.sol";

/// @title  LimitTradeManager
contract LimitTradeManager is Ownable {

    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    struct Deposit {
        uint256 tokenId;
        uint256 block;
    }

    /// @dev depositIndex[address] => array of ids
    mapping(address => uint256[]) public depositIndex;

    /// @dev deposits per id/count
    mapping (uint256 => Deposit) public deposits;

    /// @dev owner per tokenId
    mapping (uint256 => address) public tokenOwner;

    /// @dev deposit count
    uint256 public depositCount;

    address public controller;

    address public keeper;

    INonfungiblePositionManager public immutable nonfungiblePositionManager;

    IWETH9 public WETH;

    IUniswapV3Factory factory;

    int24 public limitMargin;

    constructor(address _controller, address _keeper, int24 _limitMargin,
            INonfungiblePositionManager _nonfungiblePositionManager,
            IUniswapV3Factory _factory,
            IWETH9 _WETH) {

        controller = _controller;
        keeper = _keeper;
        limitMargin = _limitMargin;

        nonfungiblePositionManager = _nonfungiblePositionManager;
        factory = _factory;
        WETH = _WETH;
    }

    function createLimitTrade(address _token0, address _token1, uint256 _amount0, uint256 _amount1,
        uint160 _targetSqrtPriceX96 , uint24 _fee) external {

        address _poolAddress = factory.getPool(_token0, _token1, _fee);
        require (_poolAddress != address(0), "POOL_NOT_FOUND");

        (int24 _lowerTick, int24 _upperTick) = calculateLimitTicks(_poolAddress, _amount0, _amount1, _targetSqrtPriceX96);
        (uint256 _tokenId,,,) = _mintNewPosition(_token0, _token1, _amount0, _amount1,
            _lowerTick, _upperTick, _fee);

        // TODO signal keeper
        //ILimitSignalKeeper(keeper).onNewPosition(_tokenId);
    }

    function _mintNewPosition(address _token0, address _token1, uint256 _amount0, uint256 _amount1,
    int24 _lowerTick, int24 _upperTick,
        uint24 _fee)
    internal
    returns (
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    ) {

        if (_amount0 > 0) {
            // transfer tokens to contract
            TransferHelper.safeTransferFrom(_token0, msg.sender, address(this), _amount0);

            // Approve the position manager
            TransferHelper.safeApprove(_token0, address(nonfungiblePositionManager), _amount0);
        }

        if (_amount1 > 0) {
            // transfer tokens to contract
            TransferHelper.safeTransferFrom(_token1, msg.sender, address(this), _amount1);

            // Approve the position manager
            TransferHelper.safeApprove(_token1, address(nonfungiblePositionManager), _amount1);
        }

        INonfungiblePositionManager.MintParams memory params =
        INonfungiblePositionManager.MintParams({
            token0: _token0,
            token1: _token1,
            fee: _fee,
            tickLower: _lowerTick,
            tickUpper: _upperTick,
            amount0Desired: _amount0,
            amount1Desired: _amount1,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        (tokenId, liquidity, amount0, amount1) = nonfungiblePositionManager.mint(params);

        // Create a deposit
        depositCount++;
        Deposit memory newDeposit = Deposit({
            tokenId: tokenId,
            block: block.number
        });

        deposits[depositCount] = newDeposit;
        depositIndex[msg.sender].push(depositCount);
        tokenOwner[tokenId] = msg.sender;

        // Remove allowance and refund in both assets.
        if (amount0 < _amount0) {
            TransferHelper.safeApprove(_token0, address(nonfungiblePositionManager), 0);
            uint256 _refund0 = _amount0 - amount0;
            TransferHelper.safeTransfer(_token0, msg.sender, _refund0);
        }

        if (amount1 < _amount1) {
            TransferHelper.safeApprove(_token1, address(nonfungiblePositionManager), 0);
            uint256 _refund1 = _amount1 - amount1;
            TransferHelper.safeTransfer(_token1, msg.sender, _refund1);
        }
    }

    function depositIndexLength(address user) external view returns (uint256) {
        return depositIndex[user].length;
    }

    function calculateLimitTicks(address _poolAddress, uint256 _amount0, uint256 _amount1,
        uint160 _targetSqrtPriceX96) public view
        returns (int24 _lowerTick, int24 _upperTick) {

        IUniswapV3Pool _pool = IUniswapV3Pool(_poolAddress);
        int24 tickSpacing = _pool.tickSpacing();
        (, int24 tick, , , , , ) = _pool.slot0();

        int24 _targetTick = TickMath.getTickAtSqrtRatio(_targetSqrtPriceX96);
        int24 tickFloor = _floor(_targetTick, tickSpacing);
        int24 tickCeil = tickFloor + tickSpacing;

        // TODO do we need to compare _target tick with current tick ?!

        return _checkBidAskLiquidity(tickFloor - limitMargin, tickFloor,
            tickCeil, tickCeil + limitMargin,
            _amount0, _amount1,
            _pool, tickSpacing);

    }

    function _checkBidAskLiquidity(int24 _bidLower, int24 _bidUpper,
        int24 _askLower, int24 _askUpper,
        uint256 _amount0, uint256 _amount1,
        IUniswapV3Pool _pool, int24 tickSpacing) internal view
    returns (int24 _lowerTick, int24 _upperTick) {

        _checkRange(_bidLower, _bidUpper, tickSpacing);
        _checkRange(_askLower, _askUpper, tickSpacing);

        uint128 bidLiquidity = _liquidityForAmounts(_pool, _bidLower, _bidUpper, _amount0, _amount1);
        uint128 askLiquidity = _liquidityForAmounts(_pool, _askLower, _askUpper, _amount0, _amount1);

        require(bidLiquidity > 0 || askLiquidity > 0, "INVALID_LIMIT_ORDER");

        if (bidLiquidity > askLiquidity) {
            (_lowerTick, _upperTick) = (_bidLower, _bidUpper);
        } else {
            (_lowerTick, _upperTick) = (_askLower, _askUpper);
        }
    }

    /// @dev Wrapper around `LiquidityAmounts.getLiquidityForAmounts()`.
    function _liquidityForAmounts(
        IUniswapV3Pool pool,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    ) internal view returns (uint128) {
        (uint160 sqrtRatioX96, , , , , , ) = pool.slot0();
        return
        LiquidityAmounts.getLiquidityForAmounts(
            sqrtRatioX96,
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper),
            amount0,
            amount1
        );
    }

    function _checkRange(int24 _tickLower, int24 _tickUpper, int24 _tickSpacing) internal view {
        require(_tickLower < _tickUpper, "tickLower < tickUpper");
        require(_tickLower >= TickMath.MIN_TICK, "tickLower too low");
        require(_tickUpper <= TickMath.MAX_TICK, "tickUpper too high");
        require(_tickLower % _tickSpacing == 0, "tickLower % tickSpacing");
        require(_tickUpper % _tickSpacing == 0, "tickUpper % tickSpacing");
    }

    /// @dev Rounds tick down towards negative infinity so that it's a multiple
    /// of `tickSpacing`.
    function _floor(int24 tick, int24 _tickSpacing) internal view returns (int24) {
        int24 compressed = tick / _tickSpacing;
        if (tick < 0 && tick % _tickSpacing != 0) compressed--;
        return compressed * _tickSpacing;
    }

    /// @dev Casts uint256 to uint128 with overflow check.
    function _toUint128(uint256 x) internal pure returns (uint128) {
        assert(x <= type(uint128).max);
        return uint128(x);
    }
}