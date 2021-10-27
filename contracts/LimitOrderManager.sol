// SPDX-License-Identifier: MIT

pragma solidity >=0.7.5;
pragma abicoder v2;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import '@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol';

import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";
import "@uniswap/v3-periphery/contracts/libraries/PoolAddress.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";

import "@uniswap/v3-periphery/contracts/interfaces/external/IWETH9.sol";
import "@uniswap/v3-periphery/contracts/interfaces/IQuoter.sol";

import "./interfaces/IOrderMonitor.sol";
import "./interfaces/IOrderManager.sol";
import "./SelfPermit.sol";
import "./Multicall.sol";

/// @title  LimitOrderManager
contract LimitOrderManager is
    IOrderManager,
    OwnableUpgradeable,
    Multicall,
    SelfPermit,
    IERC721Receiver {

    using SafeMath for uint256;

    struct Deposit {
        uint256 tokenId;
        uint256 opened;
        address token0;
        address token1;
        uint256 closed;
        uint256 batchId;
        address owner;
        uint256 ownerIndex;
        IOrderMonitor monitor;
        uint256 serviceFee;
    }

    /// @dev liquidity deadline
    uint256 private constant LIQUIDITY_DEADLINE = 60 seconds;

    /// @dev fired when a new deposit is made
    event DepositCreated(address indexed owner, uint256 indexed tokenId);

    /// @dev fired when a deposit is closed
    event DepositClosed(address indexed owner, uint256 indexed tokenId);

    /// @dev fired when a deposit is cancelled
    event DepositCancelled(address indexed owner, uint256 indexed tokenId);

    /// @dev fired when a deposit is claimed
    event DepositClaimed(address indexed owner, uint256 indexed tokenId,
        uint256 tokensOwed0, uint256 tokensOwed1, uint256 payment);

    /// @dev fired when a new funding is made
    event FundingAdded(address indexed from, uint256 amount);

    /// @dev fired when funding is withdrawn
    event FundingWithdrawn(address indexed from, uint256 amount);

    /// @dev funding
    mapping(address => uint256) public override funding;

    /// @dev reserved funds
    mapping(address => uint256) public reservedWeiFunds;

    /// @dev tokenIdsPerAddress[address] => array of token ids
    mapping(address => uint256[]) public tokenIdsPerAddress;

    /// @dev deposits per token id
    mapping (uint256 => Deposit) public deposits;

    /// @dev monitor pool
    IOrderMonitor[] public monitors;

    //  @dev last monitor index + 1 ; always > 0
    uint256 public nextMonitor;

    /// @dev uniV3 position manager
    INonfungiblePositionManager public nonfungiblePositionManager;

    /// @dev wrapper ETH
    IWETH9 public WETH;

    /// @dev univ3 factory
    IUniswapV3Factory public factory;

    /// @dev quoter V2
    IQuoter public quoter;

    /// @dev krom token
    IERC20 public KROM;

    /// @dev order monitoring gas usage
    uint256 public monitorGasUsage;

    /// @notice Initializes the smart contract instead of a constructor
    /// @param _nonfungiblePositionManager univ3 nftmanager
    /// @param _factory univ3 factory
    /// @param _WETH wrapped ETH
    /// @param _KROM kromatika token
    /// @param _monitorGasUsage gas usage of the order monitor
    function initialize(INonfungiblePositionManager _nonfungiblePositionManager,
            IUniswapV3Factory _factory,
            IWETH9 _WETH,
            IERC20 _KROM,
            IQuoter _quoter,
            uint256 _monitorGasUsage) external initializer {

        nonfungiblePositionManager = _nonfungiblePositionManager;
        factory = _factory;
        WETH = _WETH;
        KROM = _KROM;
        quoter = _quoter;

        monitorGasUsage = _monitorGasUsage;

        OwnableUpgradeable.__Ownable_init();
    }

    function openOrder(address _token0, address _token1, uint24 _fee, uint160 _sqrtPriceX96,
        uint256 _amount0, uint256 _amount1, uint256 _targetGasPrice)
        external payable returns (uint256 _tokenId) {

        int24 _lowerTick;
        int24 _upperTick;
        {

            address _poolAddress = factory.getPool(_token0, _token1, _fee);
            require (_poolAddress != address(0), "POOL_NOT_FOUND");

            (_lowerTick, _upperTick) = calculateLimitTicks(
                _poolAddress, _amount0, _amount1, _sqrtPriceX96
            );
        }

        (_tokenId,,_amount0,_amount1) = _mintNewPosition(
            _token0, _token1, _amount0, _amount1, _lowerTick, _upperTick, _fee, msg.sender
        );

        _createDeposit(
            _tokenId, _token0, _token1,
            _amount0, _amount1, msg.sender, _targetGasPrice);
    }

    function closeOrder(uint256 _tokenId, uint256 _batchId) external override
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


    function cancelOrder(uint256 _tokenId) external payable
    returns (uint256 _amount0, uint256 _amount1) {

        Deposit storage deposit = deposits[_tokenId];
        require(deposit.closed == 0, "DEPOSIT_CLOSED");
        require(deposit.owner == msg.sender, "NOT_OWNER");

        // update the state
        deposit.closed = block.number;

        // remove liquidity
        (_amount0, _amount1) = _removeLiquidity(_tokenId);
        // stop monitor
        deposit.monitor.stopMonitor(_tokenId);
        // claim the funds
        _claimOrderFunds(_tokenId);

        emit DepositCancelled(deposit.owner, _tokenId);
    }

    function claimOrderFunds(uint256 _tokenId) external {

        _claimOrderFunds(_tokenId);
    }

    function addFunding(uint256 _amount) external {

        funding[msg.sender] = funding[msg.sender].add(_amount);
        TransferHelper.safeTransferFrom(address(KROM), msg.sender, address(this), _amount);
        emit FundingAdded(msg.sender, _amount);
    }

    function withdrawFunding(uint256 _amount) external {

        uint256 balance = funding[msg.sender];
        uint256 reservedKROM = quoteKROM(reservedWeiFunds[msg.sender]);

        require(balance >= _amount, "NOT_ENOUGH_BALANCE");
        balance = balance.sub(_amount);
        require(balance >= reservedKROM, "NOT_ENOUGH_RESERVES");

        funding[msg.sender] = balance;
        TransferHelper.safeTransfer(address(KROM), msg.sender, _amount);
        emit FundingWithdrawn(msg.sender, _amount);
    }

    function retrieveToken(uint256 _tokenId) external {

        Deposit storage deposit = deposits[_tokenId];

        // must be the owner of the deposit
        require(msg.sender == deposit.owner, 'NOT_OWNER');
        // must not be closed
        require(deposit.closed == 0, "DEPOSIT_CLOSED");
        // transfer ownership to original owner
        nonfungiblePositionManager.safeTransferFrom(address(this), msg.sender, _tokenId);
        // stop monitoring
        deposit.monitor.stopMonitor(_tokenId);

        // remove information related to tokenId
        tokenIdsPerAddress[msg.sender] = removeElementFromArray(
            deposit.ownerIndex, tokenIdsPerAddress[msg.sender]
        );
        reservedWeiFunds[deposit.owner] = reservedWeiFunds[deposit.owner].sub(deposit.serviceFee);
        delete deposits[_tokenId];
    }

    // Implementing `onERC721Received` so this contract can receive custody of erc721 tokens
    function onERC721Received(
        address _operator,
        address,
        uint256 _tokenId,
        bytes calldata
    ) external override returns (bytes4) {

        uint256 _amount0;
        uint256 _amount1;
        address _token0;
        address _token1;

        {

            (, , address _t0, address _t1, uint24 _fee , int24 tickLower , int24 tickUpper , uint128 liquidity , , , , ) =
            nonfungiblePositionManager.positions(_tokenId);

            _token0 = _t0;
            _token1 = _t1;

            address _poolAddress = factory.getPool(_token0, _token1, _fee);
            require (_poolAddress != address(0), "POOL_NOT_FOUND");

            (_amount0, _amount1) = _amountsForLiquidity(IUniswapV3Pool(_poolAddress),
                tickLower, tickUpper, liquidity);
        }

        // only transfer custody of one-sided range liquidity
        require(_amount0 == 0 || _amount1 == 0, "INVALID_TOKEN");

        // TODO (pai) parse the call data to get the _targetGasPrice

        // create a deposit for the operator
        _createDeposit(_tokenId, _token0, _token1, _amount0, _amount1, _operator, 0);

        return this.onERC721Received.selector;
    }

    function quoteKROM(uint256 _weiAmount) public returns (uint256 quote) {
        // TODO replace with price oracle if/when avail
        address _poolAddress = factory.getPool(address(WETH), address(KROM), 3000);
        if (_poolAddress == address(0)) {
            return 0;
        }
        quote = quoter.quoteExactInputSingle(
            address(WETH), address(KROM), 3000, _weiAmount, 0
        );
    }

    function isUnderfunded(address _owner) external override returns (
        bool underfunded, uint256 amount
    ) {
        uint256 reservedKROM = quoteKROM(reservedWeiFunds[_owner]);
        uint256 balance = funding[_owner];

        if (reservedKROM > balance) {
            underfunded = true;
            amount = reservedKROM.sub(balance);
        }
    }

    function setMonitors(IOrderMonitor[] calldata _newMonitors) external onlyOwner {

        require(_newMonitors.length > 0, "NO_MONITORS");
        monitors = _newMonitors;
    }

    function setMonitorGasUsage(uint256 _monitorGasUsage) external onlyOwner {

        monitorGasUsage = _monitorGasUsage;
    }

    function estimateServiceFeeWei(uint256 _targetGasPrice) public view returns (uint256) {
        return monitorGasUsage.mul(_targetGasPrice);
    }

    function tokenIdsPerAddressLength(address user) external view returns (uint256) {
        return tokenIdsPerAddress[user].length;
    }

    function calculateLimitTicks(address _poolAddress, uint256 _amount0, uint256 _amount1,
        uint160 _sqrtPriceX96) public view
    returns (int24 _lowerTick, int24 _upperTick) {

        IUniswapV3Pool _pool = IUniswapV3Pool(_poolAddress);
        int24 tickSpacing = _pool.tickSpacing();
        (, int24 tick, , , , , ) = _pool.slot0();

        int24 _targetTick = TickMath.getTickAtSqrtRatio(_sqrtPriceX96);
        int24 tickFloor = _floor(_targetTick, tickSpacing);
        int24 tickCeil = tickFloor + tickSpacing;

        require(tick != _targetTick, "SAME_TICKS");

        return _checkLiquidityRange(tickFloor - tickSpacing, tickFloor,
            tickCeil, tickCeil + tickSpacing,
            _amount0, _amount1,
            _pool, tickSpacing);

    }

    function _createDeposit(uint256 _tokenId, address _token0, address _token1,
        uint256 _amount0, uint256 _amount1, address _owner, uint256 _targetGasPrice) internal {

        // first check the funding for the deposit
        uint256 _serviceFeeWei = estimateServiceFeeWei(_targetGasPrice);
        reservedWeiFunds[_owner] = reservedWeiFunds[_owner].add(_serviceFeeWei);

        IOrderMonitor _monitor = _selectMonitor();
        tokenIdsPerAddress[_owner].push(_tokenId);

        // Create a deposit
        Deposit memory newDeposit = Deposit({
            tokenId: _tokenId,
            opened: block.number,
            token0: _token0,
            token1: _token1,
            closed: 0,
            batchId: 0,
            owner: _owner,
            ownerIndex: tokenIdsPerAddress[_owner].length - 1,
            monitor: _monitor,
            serviceFee: _serviceFeeWei
        });

        deposits[_tokenId] = newDeposit;

        _monitor.startMonitor(_tokenId, _amount0, _amount1, _targetGasPrice, _owner);

        emit DepositCreated(_owner, _tokenId);

    }

    function _claimOrderFunds(uint256 _tokenId) internal {

        Deposit storage deposit = deposits[_tokenId];
        require(deposit.closed > 0, "DEPOSIT_NOT_CLOSED");

        uint256 balance = funding[deposit.owner];
        (uint256 payment, address creator) = deposit.monitor.batchInfo(deposit.batchId);
        require(balance > 0 && payment <= balance, "NO_FUNDING");

        balance = balance.sub(payment);
        funding[deposit.owner] = balance;
        reservedWeiFunds[deposit.owner] = reservedWeiFunds[deposit.owner].sub(deposit.serviceFee);

        INonfungiblePositionManager.CollectParams memory collectParams =
        INonfungiblePositionManager.CollectParams({
            tokenId: _tokenId,
            recipient: address(this),
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        });

        // collect everything
        (uint256 _tokensToSend0, uint256 _tokensToSend1) = nonfungiblePositionManager.collect(collectParams);
        require(_tokensToSend0 > 0 || _tokensToSend1 > 0, "NO_TOKENS_OWED");

        // close the position
        nonfungiblePositionManager.burn(_tokenId);

        _transferToOwner(deposit.token0, _tokensToSend0, deposit.owner);
        _transferToOwner(deposit.token1, _tokensToSend1, deposit.owner);
        _transferToOwner(address(KROM), payment, creator);

        emit DepositClaimed(msg.sender, _tokenId, _tokensToSend0, _tokensToSend1, payment);
    }

    function _selectMonitor() internal returns (IOrderMonitor _monitor) {

        uint256 monitorLength = monitors.length;
        require(monitorLength > 0, "NO_MONITORS");

        uint256 _selectedIndex = nextMonitor == monitorLength
            ? 0
            : nextMonitor;

        _monitor = monitors[_selectedIndex];
        nextMonitor = _selectedIndex.add(1);
    }

    function _checkLiquidityRange(int24 _bidLower, int24 _bidUpper,
        int24 _askLower, int24 _askUpper,
        uint256 _amount0, uint256 _amount1,
        IUniswapV3Pool _pool, int24 _tickSpacing) internal view
    returns (int24 _lowerTick, int24 _upperTick) {

        _checkRange(_bidLower, _bidUpper, _tickSpacing);
        _checkRange(_askLower, _askUpper, _tickSpacing);

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

    /// @dev Wrapper around `LiquidityAmounts.getAmountsForLiquidity()`.
    function _amountsForLiquidity(
        IUniswapV3Pool pool,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) internal view returns (uint256, uint256) {
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

    /// @notice Removes index element from the given array.
    /// @param  index index to remove from the array
    /// @param  array the array itself
    function removeElementFromArray(uint256 index, uint256[] storage array) private returns (uint256[] memory) {
        if (index == array.length - 1) {
            array.pop();
        } else {
            array[index] = array[array.length - 1];
            array.pop();
        }
        return array;
    }

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

        INonfungiblePositionManager.MintParams memory mintParams =
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
            deadline: block.timestamp.add(LIQUIDITY_DEADLINE)
        });

        (tokenId,liquidity,amount0,amount1) = nonfungiblePositionManager.mint(mintParams);

        // Remove allowance and refund in both assets.
        if (amount0 < _amount0) {
            _removeAllowanceAndRefund(_token0, _amount0.sub(amount0), _owner);
        }

        if (amount1 < _amount1) {
            _removeAllowanceAndRefund(_token1, _amount1.sub(amount1), _owner);
        }
    }

    /// @dev Approve transfer to position manager
    function _approveAndTransferToUniswap(address _token, uint256 _amount, address _owner) private {

        if (_amount > 0) {
            // transfer tokens to contract
            if (_token == address(WETH)) {
                // if _token is WETH --> wrap it first
                WETH.deposit{value: _amount}();
            } else {
                TransferHelper.safeTransferFrom(_token, _owner, address(this), _amount);
            }

            // Approve the position manager
            TransferHelper.safeApprove(_token, address(nonfungiblePositionManager), _amount);
        }
    }

    /// @dev Remove allowance and refund
    function _removeAllowanceAndRefund(address _token, uint256 _amount, address _owner) private {

        TransferHelper.safeApprove(_token, address(nonfungiblePositionManager), 0);
        _transferToOwner(_token, _amount, _owner);
    }

    function _transferToOwner(address _token, uint256 _amount, address _owner) private {
        if (_amount > 0) {
            if (_token == address(WETH)) {
                // if token is WETH, withdraw and send back ETH
                WETH.withdraw(_amount);
                TransferHelper.safeTransferETH(_owner, _amount);
            } else {
                TransferHelper.safeTransfer(_token, _owner, _amount);
            }
        }
    }

    function _removeLiquidity(uint256 _tokenId)
    internal
    returns (
        uint256 amount0,
        uint256 amount1
    ) {

        (,,,,,,,uint128 _liquidity,,,,) = nonfungiblePositionManager.positions(_tokenId);

        INonfungiblePositionManager.DecreaseLiquidityParams memory removeParams =
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: _tokenId,
                liquidity: _liquidity,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp.add(LIQUIDITY_DEADLINE)
        });

        (amount0, amount1) = nonfungiblePositionManager.decreaseLiquidity(removeParams);
    }

    // Function to receive Ether. msg.data must be empty
    receive() external payable {}

    // Fallback function is called when msg.data is not empty
    fallback() external payable {}
}