// SPDX-License-Identifier: MIT

pragma solidity >=0.7.5;
pragma abicoder v2;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";
import "@uniswap/v3-periphery/contracts/libraries/PoolAddress.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";

import "@uniswap/v3-periphery/contracts/interfaces/external/IWETH9.sol";

import "./interfaces/ILimitTradeMonitor.sol";
import "./interfaces/ILimitTradeManager.sol";

/// @title  LimitTradeManager
contract LimitTradeManager is ILimitTradeManager, Ownable {

    using SafeMath for uint256;

    struct Deposit {
        uint256 tokenId;
        uint256 opened;
        address token0;
        address token1;
        uint256 closed;
        uint256 batchId;
        address owner;
        ILimitTradeMonitor monitor;
    }

    event DepositCreated(address indexed owner, uint256 indexed tokenId);

    event DepositClosed(address indexed owner, uint256 indexed tokenId);

    event DepositClaimed(address indexed owner, uint256 indexed tokenId,
        uint256 tokensOwed0, uint256 tokensOwed1, uint256 payment);

    /// @dev tokenIdsPerAddress[address] => array of token ids
    mapping(address => uint256[]) public tokenIdsPerAddress;

    /// @dev deposits per token id
    mapping (uint256 => Deposit) public deposits;

    /// @dev monitor pool
    ILimitTradeMonitor[] public monitors;

    //  @dev last monitor index + 1 ; always > 0
    uint256 public nextMonitor;

    /// @dev uniV3 position manager
    INonfungiblePositionManager public immutable nonfungiblePositionManager;

    /// @dev wrapper ETH
    IWETH9 public WETH;

    /// @dev univ3 factory
    IUniswapV3Factory public factory;

    constructor(INonfungiblePositionManager _nonfungiblePositionManager,
            IUniswapV3Factory _factory,
            IWETH9 _WETH) {

        nonfungiblePositionManager = _nonfungiblePositionManager;
        factory = _factory;
        WETH = _WETH;
    }

    function openLimitTrade(address _token0, address _token1, uint256 _amount0, uint256 _amount1,
        uint160 _targetSqrtPriceX96 , uint24 _fee) external returns (uint256 _tokenId) {

        address _poolAddress = factory.getPool(_token0, _token1, _fee);
        require (_poolAddress != address(0), "POOL_NOT_FOUND");

        (int24 _lowerTick, int24 _upperTick) = calculateLimitTicks(
            _poolAddress, _amount0, _amount1, _targetSqrtPriceX96
        );
        (_tokenId,,_amount0,_amount1) = _mintNewPosition(
            _token0, _token1, _amount0, _amount1, _lowerTick, _upperTick, _fee, msg.sender
        );

        ILimitTradeMonitor _monitor = _selectMonitor();

        // Create a deposit
        Deposit memory newDeposit = Deposit({
            tokenId: _tokenId,
            opened: block.number,
            token0: _token0,
            token1: _token1,
            closed: 0,
            batchId: 0,
            owner: msg.sender,
            monitor: _monitor
        });

        deposits[_tokenId] = newDeposit;
        tokenIdsPerAddress[msg.sender].push(_tokenId);

        _monitor.startMonitor(_tokenId, _amount0, _amount1);

        emit DepositCreated(msg.sender, _tokenId);
    }

    function closeLimitTrade(uint256 _tokenId, uint256 _batchId) external override
        returns (uint256 _amount0, uint256 _amount1) {

        Deposit storage deposit = deposits[_tokenId];
        require(msg.sender == address(deposit.monitor), "NOT_MONITOR");
        require(deposit.closed == 0, "DEPOSIT_CLOSED");

        // update the state
        deposit.closed = block.number;
        deposit.batchId = _batchId;

        (_amount0, _amount1) = _removeLiquidity(_tokenId);

        emit DepositClosed(deposit.owner, _tokenId);
    }


    function fastCloseLimitTrade(uint256 _tokenId) external
    returns (uint256 _amount0, uint256 _amount1) {

        Deposit storage deposit = deposits[_tokenId];
        require(deposit.closed == 0, "DEPOSIT_CLOSED");
        require(deposit.owner == msg.sender, "NOT_OWNER");

        // update the state
        deposit.closed = block.number;
        deposit.monitor.stopMonitor(_tokenId);

        // remove liquidity
        (_amount0, _amount1) = _removeLiquidity(_tokenId);
        // collect the fees
        (_amount0, _amount1) = _collectTokensOwed(_tokenId, deposit.owner);
        // burn the position
        nonfungiblePositionManager.burn(_tokenId);

        emit DepositClosed(deposit.owner, _tokenId);
    }

    function claimLimitTrade(uint256 _tokenId) external payable {
        _claimLimitTrade(_tokenId);
    }

    function batchClaim(uint256[] calldata tokenIds) external payable {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            _claimLimitTrade(tokenIds[i]);
        }
    }

    function addMonitor(ILimitTradeMonitor _newMonitor) external onlyOwner {
        require(address(_newMonitor) != address(0), "ZERO_ADDRESS");
        monitors.push(_newMonitor);
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

    function _claimLimitTrade(uint256 _tokenId) internal {

        // TODO implement minting of governance token proportional to the claiming _tokenId

        Deposit storage deposit = deposits[_tokenId];
        require(deposit.closed > 0, "DEPOSIT_NOT_CLOSED");

        (uint256 payment, address creator) = deposit.monitor.batchInfo(deposit.batchId);
        require(payment <= msg.value, "NO_PAYMENT");

        // collect the fees
        (uint256 _tokensToSend0, uint256 _tokensToSend1) = _collectTokensOwed(_tokenId, deposit.owner);

        // close the position
        nonfungiblePositionManager.burn(_tokenId);

        require(_tokensToSend0 > 0 || _tokensToSend1 > 0, "NO_TOKENS_OWED");

        // TODO charge service fee
        // payment = _chargeFee(payment);
        // if using Chainlink keepers, convert ETH to LINK before sending to the creator
        TransferHelper.safeTransferETH(creator, payment);

        emit DepositClaimed(msg.sender, _tokenId, _tokensToSend0, _tokensToSend1, msg.value);
    }

    function _removeLiquidity(uint256 _tokenId) internal
        returns (uint256 _amount0, uint256 _amount1) {

        (,,,,,,,uint128 liquidity,,,,) = nonfungiblePositionManager.positions(_tokenId);

        if (liquidity > 0) {
            (_amount0, _amount1) = _removeLiquidity(_tokenId, liquidity);
        }
    }

    function _selectMonitor() internal returns (ILimitTradeMonitor _monitor) {

        uint256 monitorLength = monitors.length;
        require(monitorLength > 0, "NO_MONITORS");

        uint256 _selectedIndex = nextMonitor == monitorLength
            ? 0
            : nextMonitor;

        _monitor = monitors[_selectedIndex];
        nextMonitor = _selectedIndex + 1;
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

    function _checkRange(int24 _tickLower, int24 _tickUpper, int24 _tickSpacing) internal pure {
        require(_tickLower < _tickUpper, "tickLower < tickUpper");
        require(_tickLower >= TickMath.MIN_TICK, "tickLower too low");
        require(_tickUpper <= TickMath.MAX_TICK, "tickUpper too high");
        require(_tickLower % _tickSpacing == 0, "tickLower % tickSpacing");
        require(_tickUpper % _tickSpacing == 0, "tickUpper % tickSpacing");
    }

    /// @dev Rounds tick down towards negative infinity so that it's a multiple
    /// of `tickSpacing`.
    function _floor(int24 tick, int24 _tickSpacing) internal pure returns (int24) {
        int24 compressed = tick / _tickSpacing;
        if (tick < 0 && tick % _tickSpacing != 0) compressed--;
        return compressed * _tickSpacing;
    }

    /// @dev Casts uint256 to uint128 with overflow check.
    function _toUint128(uint256 x) internal pure returns (uint128) {
        assert(x <= type(uint128).max);
        return uint128(x);
    }

//    function _chargeFee(uint256 payment) private returns (uint256) {
//        uint256 feeDue = payment.mul(serviceFee).div(10**23);
//        TransferHelper.safeTransferETH(serviceProvider, feeDue);
//        return payment.sub(feeDue);
//    }

    function _mintNewPosition(address _token0, address _token1, uint256 _amount0, uint256 _amount1,
        int24 _lowerTick, int24 _upperTick,
        uint24 _fee,
        address _owner)
    private
    returns (
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    ) {

        _approveAndTransferToUniswap(_token0, _amount0, _owner);
        _approveAndTransferToUniswap(_token1, _amount1, _owner);

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
            _removeAllowanceAndRefund(_token0, _amount0 - amount0, _owner);
        }

        if (amount1 < _amount1) {
            _removeAllowanceAndRefund(_token1, _amount1 - amount1, _owner);
        }
    }

    /// @dev Approve transfer to position manager
    function _approveAndTransferToUniswap(address _token, uint256 _amount, address _owner) private {

        if (_amount > 0) {
            // transfer tokens to contract
            TransferHelper.safeTransferFrom(_token, _owner, address(this), _amount);

            // Approve the position manager
            TransferHelper.safeApprove(_token, address(nonfungiblePositionManager), _amount);
        }
    }

    /// @dev Remove allowance and refund
    function _removeAllowanceAndRefund(address _token, uint256 _amount, address _owner) private {
        TransferHelper.safeApprove(_token, address(nonfungiblePositionManager), 0);
        TransferHelper.safeTransfer(_token, _owner, _amount);
    }

    function _collectTokensOwed(uint256 _tokenId, address _owner)
    private
    returns (
        uint256 _amount0,
        uint256 _amount1
    ) {

        INonfungiblePositionManager.CollectParams memory params =
            INonfungiblePositionManager.CollectParams({
                tokenId: _tokenId,
                recipient: _owner,
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