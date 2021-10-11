// SPDX-License-Identifier: MIT

pragma solidity >=0.7.5;
pragma abicoder v2;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import '@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol';
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/cryptography/ECDSA.sol";

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

import "./interfaces/ILimitSignalKeeper.sol";
import "./interfaces/ILimitTradeManager.sol";

/// @title  LimitTradeManager
contract LimitTradeManager is ILimitTradeManager, Ownable {

    using SafeMath for uint256;

    struct Deposit {
        uint256 tokenId;
        uint256 opened;
        address token0;
        address token1;
        uint256 tokensOwed0;
        uint256 tokensOwed1;
        uint256 closed;
        uint256 batchId;
        address owner;
    }

    event DepositCreated(address indexed owner, uint256 indexed tokenId);

    event DepositClosed(address indexed owner, uint256 indexed tokenId);

    event DepositClaimed(address indexed owner, uint256 indexed tokenId,
        uint256 tokensOwed0, uint256 tokensOwed1, uint256 payment);

    /// @dev tokenIdsPerAddress[address] => array of token ids
    mapping(address => uint256[]) public tokenIdsPerAddress;

    /// @dev deposits per token id
    mapping (uint256 => Deposit) public deposits;

    /// @dev keeper contract
    ILimitSignalKeeper public keeper;

    /// @dev uniV3 position manager
    INonfungiblePositionManager public immutable nonfungiblePositionManager;

    /// @dev wrapper ETH
    IWETH9 public WETH;

    /// @dev univ3 factory
    IUniswapV3Factory factory;

    /// @dev only keeper
    modifier onlyKeeper() {
        require(msg.sender == address(keeper), "NOT_KEEPER");
        _;
    }

    constructor(ILimitSignalKeeper _keeper,
            INonfungiblePositionManager _nonfungiblePositionManager,
            IUniswapV3Factory _factory,
            IWETH9 _WETH) {

        keeper = _keeper;

        nonfungiblePositionManager = _nonfungiblePositionManager;
        factory = _factory;
        WETH = _WETH;
    }

    function createLimitTrade(address _token0, address _token1, uint256 _amount0, uint256 _amount1,
        uint160 _targetSqrtPriceX96 , uint24 _fee) external returns (uint256 _tokenId) {

        address _poolAddress = factory.getPool(_token0, _token1, _fee);
        require (_poolAddress != address(0), "POOL_NOT_FOUND");

        (int24 _lowerTick, int24 _upperTick) = calculateLimitTicks(
            _poolAddress, _amount0, _amount1, _targetSqrtPriceX96
        );
        (_tokenId,,_amount0,_amount1) = _mintNewPosition(
            _token0, _token1, _amount0, _amount1, _lowerTick, _upperTick, _fee
        );

        // Create a deposit
        Deposit memory newDeposit = Deposit({
            tokenId: _tokenId,
            opened: block.number,
            token0: _token0,
            token1: _token1,
            tokensOwed0: 0,
            tokensOwed1: 0,
            closed: 0,
            batchId: 0,
            owner: msg.sender
        });

        deposits[_tokenId] = newDeposit;
        tokenIdsPerAddress[msg.sender].push(_tokenId);

        keeper.startMonitor(_tokenId, _amount0, _amount1);

        emit DepositCreated(msg.sender, _tokenId);
    }

    function closeLimitTrade(uint256 _tokenId, uint256 _batchId) external override onlyKeeper
        returns (uint256 _amount0, uint256 _amount1) {

        Deposit storage deposit = deposits[_tokenId];
        require(deposit.closed == 0, "DEPOSIT_CLOSED");

        uint256 tokensOwed0;
        uint256 tokensOwed1;

        (,,,,,,,uint128 liquidity,,,,) = nonfungiblePositionManager.positions(_tokenId);

        if (liquidity > 0) {
            (tokensOwed0, tokensOwed1) = _removeLiquidity(_tokenId, liquidity);
        }

        if (tokensOwed0 > 0 || tokensOwed1 > 0) {
            (tokensOwed0, tokensOwed1) = _collectTokensOwed(_tokenId);
            _amount0 += tokensOwed0;
            _amount1 += tokensOwed1;
        }

        // update the state
        deposit.closed = block.number;
        deposit.batchId = _batchId;
        deposit.tokensOwed0 = _amount0;
        deposit.tokensOwed1 = _amount1;

        // close the position
        nonfungiblePositionManager.burn(_tokenId);

        emit DepositClosed(deposit.owner, _tokenId);
    }

    function claimLimitTrade(uint256 _tokenId) external payable {

        // TODO
        // 1. when claiming we need to know in which batchId this tokenId was included.
        // 2. when we find it, owedAmount is the ETH amount to be paid by the owner.
        // 3. the owedAmount will be send to treasury and will be used to replenish the keeper LINK funds.

        Deposit storage deposit = deposits[_tokenId];
        require(deposit.closed > 0, "DEPOSIT_NOT_CLOSED");
        require(deposit.owner == msg.sender, "ONLY_OWNER");

        (uint256 count, uint256 gasCost) = keeper.batchInfo(deposit.batchId);
        require(gasCost.div(count) <= msg.value, "NO_COMPENSATION");

        uint256 _tokensToSend = deposit.tokensOwed0;

        if (_tokensToSend > 0) {
            deposit.tokensOwed0 = 0;
            TransferHelper.safeTransfer(deposit.token0, deposit.owner, _tokensToSend);
        }

        _tokensToSend = deposit.tokensOwed1;
        if (_tokensToSend > 0) {
            deposit.tokensOwed1 = 0;
            TransferHelper.safeTransfer(deposit.token1, deposit.owner, _tokensToSend);
        }

        // TODO send the msg.value to treasury
        emit DepositClaimed(msg.sender, _tokenId, deposit.tokensOwed0, deposit.tokensOwed1, msg.value);
    }

    function changeKeeper(address _newKeeper) external onlyOwner {
        keeper = _newKeeper;
    }

    function tokenIdsPerAddressLength(address user) external view returns (uint256) {
        return tokenIdsPerAddress[user].length;
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

        require(tick != _targetTick, "SAME_TICKS");

        return _checkBidAskLiquidity(tickFloor - tickSpacing, tickFloor,
            tickCeil, tickCeil + tickSpacing,
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

    function _mintNewPosition(address _token0, address _token1, uint256 _amount0, uint256 _amount1,
        int24 _lowerTick, int24 _upperTick,
        uint24 _fee)
    private
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

        (tokenId,liquidity,amount0,amount1) = nonfungiblePositionManager.mint(params);

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

    function _collectTokensOwed(uint256 _tokenId)
    private
    returns (
        uint256 _amount0,
        uint256 _amount1
    ) {

        INonfungiblePositionManager.CollectParams memory params =
            INonfungiblePositionManager.CollectParams({
                tokenId: _tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
        });

        // collect everything
        (_amount0, _amount1) = nonfungiblePositionManager.collect(params);
    }

    function _removeLiquidity(uint256 _tokenId, uint128 _liquidityToRemove)
    private
    returns (
        uint256 amount0,
        uint256 amount1
    ) {
        INonfungiblePositionManager.DecreaseLiquidityParams memory params =
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: _tokenId,
                liquidity: _liquidityToRemove,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
        });

        (amount0, amount1) = nonfungiblePositionManager.decreaseLiquidity(params);
    }
}