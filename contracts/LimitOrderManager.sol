// SPDX-License-Identifier: MIT

pragma solidity >=0.7.5;
pragma abicoder v2;

import "@openzeppelin/contracts/math/SafeMath.sol";
import '@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol';
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";
import "@uniswap/v3-periphery/contracts/libraries/PoolAddress.sol";
import "@uniswap/v3-periphery/contracts/libraries/OracleLibrary.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3MintCallback.sol";
import "@uniswap/v3-periphery/contracts/libraries/CallbackValidation.sol";

import "@uniswap/v3-periphery/contracts/interfaces/external/IWETH9.sol";

import "./interfaces/IOrderMonitor.sol";
import "./interfaces/IOrderManager.sol";
import "./SelfPermit.sol";
import "./Multicall.sol";
import "./UniswapUtils.sol";

/// @title  LimitOrderManager
contract LimitOrderManager is
    IOrderManager,
    ERC721Upgradeable,
    OwnableUpgradeable,
    IUniswapV3MintCallback,
    Multicall,
    SelfPermit {

    using SafeMath for uint256;

    struct LimitOrder {
        uint256 tokenId;
        IUniswapV3Pool pool;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 opened;
        uint256 processed;
        uint256 batchId;
        IOrderMonitor monitor;
        uint256 serviceFee;
        uint256 serviceFeePaid;
        uint256 targetGasPrice;
        uint256 tokensOwed0;
        uint256 tokensOwed1;
    }

     struct MintCallbackData {
        PoolAddress.PoolKey poolKey;
        address payer;
    }

    /// @dev liquidity deadline
    uint256 private constant LIQUIDITY_DEADLINE = 60 seconds;

    uint24 public constant POOL_FEE = 3000;

    uint32 public constant TWAP_PERIOD = 60;

    /// @dev fired when a new limitOrder is placed
    event LimitOrderCreated(address indexed owner, uint256 indexed tokenId,
        uint128 orderType, uint160 sqrtPriceX96, uint256 amount0, uint256 amount1);

    /// @dev fired when a an order is processed
    event LimitOrderProcessed(address indexed monitor, uint256 indexed tokenId,
        uint256 batchId, uint256 serviceFeePaid);

    /// @dev fired when an order is cancelled
    event LimitOrderCancelled(address indexed owner, uint256 indexed tokenId, uint256 amount0, uint256 amount1);

    /// @dev fired when an order is collected
    event LimitOrderCollected(address indexed owner, uint256 indexed tokenId,
        uint256 tokensOwed0, uint256 tokensOwed1, uint256 payment);

    /// @dev fired when a new funding is made
    event FundingAdded(address indexed from, uint256 amount);

    /// @dev fired when funding is withdrawn
    event FundingWithdrawn(address indexed from, uint256 amount);

    /// @dev funding
    mapping(address => uint256) public override funding;

    /// @dev reserved funds
    mapping(address => uint256) public reservedWeiFunds;

    /// @dev limitOrders per token id
    mapping (uint256 => LimitOrder) private limitOrders;

    /// @dev monitor pool
    IOrderMonitor[] public monitors;

    /// @dev wrapper ETH
    IWETH9 public WETH;

    /// @dev univ3 factory
    IUniswapV3Factory public factory;

    /// @dev krom token
    IERC20 public KROM;

    /// @dev order monitoring gas usage
    uint256 public monitorGasUsage;

    /// @dev last monitor index + 1 ; always > 0
    uint256 public nextMonitor;

    /// @dev The ID of the next token that will be minted. Skips 0
    uint176 private nextId;

    /// @notice Initializes the smart contract instead of a constructorr
    /// @param _factory univ3 factory
    /// @param _WETH wrapped ETH
    /// @param _KROM kromatika token
    /// @param _monitorGasUsage gas usage of the order monitor
    function initialize(IUniswapV3Factory _factory,
            IWETH9 _WETH,
            IERC20 _KROM,
            uint256 _monitorGasUsage) public initializer {

        factory = _factory;
        WETH = _WETH;
        KROM = _KROM;

        monitorGasUsage = _monitorGasUsage;
        nextId = 1;

        OwnableUpgradeable.__Ownable_init();
        ERC721Upgradeable.__ERC721_init("Kromatika Limit Position", "KROM-LM-POS");
    }

    function placeLimitOrder(LimitOrderParams calldata params)
        external payable override returns (
            uint256 _tokenId
        ) {

        int24 _tickLower;
        int24 _tickUpper;
        uint128 _liquidity;
        uint128 _orderType;
        IUniswapV3Pool _pool;

        {

            PoolAddress.PoolKey memory _poolKey =
            PoolAddress.PoolKey({
                token0: params._token0, 
                token1: params._token1, 
                fee: params._fee
            });

            address _poolAddress = PoolAddress.computeAddress(address(factory), _poolKey);
            require (_poolAddress != address(0));
            _pool = IUniswapV3Pool(_poolAddress);

            (_tickLower, _tickUpper, _liquidity, _orderType) = UniswapUtils.calculateLimitTicks(_pool, params);

            if (_liquidity > 0) {
                _pool.mint(
                    address(this), 
                    _tickLower, 
                    _tickUpper, 
                    _liquidity, 
                    abi.encode(MintCallbackData({poolKey: _poolKey, payer: msg.sender}))
                );
            }
        }

        _mint(msg.sender, (_tokenId = nextId++));

        _createLimitOrder(
            _tokenId, _pool, params,
            _tickLower, _tickUpper, _liquidity, _orderType, 
            msg.sender
        );
    }

    function processLimitOrder(uint256 _tokenId, uint256 _batchId) external override
        returns (uint256 _amount0, uint256 _amount1, uint256 _serviceFeePaid) {

        LimitOrder storage limitOrder = limitOrders[_tokenId];
        require(msg.sender == address(limitOrder.monitor));
        require(limitOrder.processed == 0);

        // update the state
        limitOrder.processed = _blockNumber();
        limitOrder.batchId = _batchId;

        (_amount0, _amount1) = _removeLiquidity(
            limitOrder.pool,
            limitOrder.tickLower, 
            limitOrder.tickUpper, 
            limitOrder.liquidity
        );

        // no liquidity for this position anymore
        limitOrder.tokensOwed0 = _amount0;
        limitOrder.tokensOwed1 = _amount1;
        limitOrder.liquidity = 0;

        // send the service fee to the monitor
        _serviceFeePaid = quoteKROM(limitOrder.serviceFee);
        limitOrder.serviceFeePaid = _serviceFeePaid;

        // update balance
        address _owner = ownerOf(_tokenId);
        uint256 balance = funding[_owner];

        // reduce balance
        balance = balance.sub(_serviceFeePaid);
        funding[_owner] = balance;

        // reduce reservedWeiFunds
        reservedWeiFunds[_owner] = reservedWeiFunds[_owner].sub(limitOrder.serviceFee);

        TransferHelper.safeTransfer(
            address(KROM), msg.sender, _serviceFeePaid
        );

        emit LimitOrderProcessed(msg.sender, _tokenId, _batchId, _serviceFeePaid);
    }


    function cancelLimitOrder(uint256 _tokenId) external
    returns (uint256 _amount0, uint256 _amount1) {

        isAuthorizedForToken(_tokenId);

        LimitOrder storage limitOrder = limitOrders[_tokenId];
        require(limitOrder.processed == 0);

        // update the state
        limitOrder.processed = _blockNumber();

        // remove liquidity
        (_amount0, _amount1) = _removeLiquidity(
            limitOrder.pool,
            limitOrder.tickLower, 
            limitOrder.tickUpper, 
            limitOrder.liquidity
        );

        limitOrder.tokensOwed0 = _amount0;
        limitOrder.tokensOwed1 = _amount1;
        limitOrder.liquidity = 0;

        // stop monitor
        limitOrder.monitor.stopMonitor(_tokenId);
        // collect the funds
        _collect(_tokenId, msg.sender);

        emit LimitOrderCancelled(msg.sender, _tokenId, _amount0, _amount1);
    }

    function collect(uint256 _tokenId) external {

        isAuthorizedForToken(_tokenId);
        _collect(_tokenId, msg.sender);
    }

    function addFunding(uint256 _amount) external {

        funding[msg.sender] = funding[msg.sender].add(_amount);
        TransferHelper.safeTransferFrom(address(KROM), msg.sender, address(this), _amount);
        emit FundingAdded(msg.sender, _amount);
    }

    function withdrawFunding(uint256 _amount) external {

        uint256 balance = funding[msg.sender];
        uint256 reservedKROM = quoteKROM(reservedWeiFunds[msg.sender]);

        balance = balance.sub(_amount);
        require(balance >= reservedKROM);

        funding[msg.sender] = balance;
        TransferHelper.safeTransfer(address(KROM), msg.sender, _amount);
        emit FundingWithdrawn(msg.sender, _amount);
    }

    function uniswapV3MintCallback(
        uint256 amount0Owed,
        uint256 amount1Owed,
        bytes calldata data
    ) external override {
        MintCallbackData memory decoded = abi.decode(data, (MintCallbackData));
        CallbackValidation.verifyCallback(address(factory), decoded.poolKey);

        _approveAndTransferToUniswap(msg.sender, decoded.poolKey.token0, amount0Owed, decoded.payer);
        _approveAndTransferToUniswap(msg.sender, decoded.poolKey.token1, amount1Owed, decoded.payer);
    }

    function orders(uint256 tokenId)
    external
    view
    returns (
        address owner,
        address token0,
        address token1,
        uint24 fee,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 opened,
        uint256 processed,
        uint256 targetGasPrice,
        uint256 tokensOwed0,
        uint256 tokensOwed1
    )
    {
        LimitOrder memory limitOrder = limitOrders[tokenId];
        require(address(limitOrder.pool) != address(0));
        return (
            ownerOf(tokenId),
            limitOrder.pool.token0(),
            limitOrder.pool.token1(),
            limitOrder.pool.fee(),
            limitOrder.tickLower,
            limitOrder.tickUpper,
            limitOrder.liquidity,
            limitOrder.opened,
            limitOrder.processed,
            limitOrder.targetGasPrice,
            limitOrder.tokensOwed0,
            limitOrder.tokensOwed1
        );
    }

    function canProcess(uint256 _tokenId, uint256 _gasPrice) external view override returns (bool) {

        LimitOrder storage limitOrder = limitOrders[_tokenId];

        (bool underfunded,) = isUnderfunded(ownerOf(_tokenId));
        if (underfunded || limitOrder.targetGasPrice < _gasPrice) {
            return false;
        }

        (uint256 amount0, uint256 amount1) =
            UniswapUtils._amountsForLiquidity(
                limitOrder.pool,
                limitOrder.tickLower,
                limitOrder.tickUpper,
                limitOrder.liquidity
            );

        if (
            limitOrder.tokensOwed0 == 0 && amount0 > 0 &&
            limitOrder.tokensOwed1 > 0 && amount1 == 0
        ) {
            return true;
        }

        if (
            limitOrder.tokensOwed0 > 0 && amount0 == 0 &&
            limitOrder.tokensOwed1 == 0 && amount1 > 0
        ) {
            return true;
        }

        return false;
    
    }

    function isUnderfunded(address _owner) public view returns (
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

        require(_newMonitors.length > 0);
        monitors = _newMonitors;
    }

    function setMonitorGasUsage(uint256 _monitorGasUsage) external onlyOwner {

        monitorGasUsage = _monitorGasUsage;
    }

    function quoteKROM(uint256 _weiAmount) public view override returns (uint256 quote) {

        address _poolAddress = factory.getPool(address(WETH), address(KROM), POOL_FEE);
        require(_poolAddress != address(0));

        if (_weiAmount > 0) {
            // consult the pool in the last TWAP_PERIOD
            int24 timeWeightedAverageTick = OracleLibrary.consult(_poolAddress, TWAP_PERIOD);
            quote = OracleLibrary.getQuoteAtTick(
                timeWeightedAverageTick, _toUint128(_weiAmount), address(WETH), address(KROM)
            );
        }
    }

    function estimateServiceFeeWei(uint256 _targetGasPrice) public view returns (uint256) {
        // TODO improve the service fee estimation --> add margin
        return monitorGasUsage.mul(_targetGasPrice);
    }

    function _createLimitOrder(
        uint256 _tokenId, IUniswapV3Pool _pool,
        LimitOrderParams memory params,
        int24 _tickLower, int24 _tickUpper, uint128 _liquidity, uint128 _orderType, 
        address _owner) internal {

        // first check the funding for the limitOrder
        uint256 _serviceFeeWei = estimateServiceFeeWei(params._targetGasPrice);
        reservedWeiFunds[_owner] = reservedWeiFunds[_owner].add(_serviceFeeWei);

        IOrderMonitor _monitor = _selectMonitor();

        // Create a limitOrder
        LimitOrder memory newLimitOrder = LimitOrder({
            tokenId: _tokenId,
            pool: _pool,
            tickLower: _tickLower,
            tickUpper: _tickUpper,
            liquidity: _liquidity,
            opened: _blockNumber(),
            processed: 0,
            batchId: 0,
            monitor: _monitor,
            serviceFee: _serviceFeeWei,
            serviceFeePaid: 0,
            targetGasPrice: params._targetGasPrice,
            tokensOwed0: params._amount0,
            tokensOwed1: params._amount1
        });

        limitOrders[_tokenId] = newLimitOrder;

        _monitor.startMonitor(_tokenId);

        emit LimitOrderCreated(
            _owner,
            _tokenId,
            _orderType,
            params._sqrtPriceX96,
            params._amount0,
            params._amount1
        );

    }

    function _collect(uint256 _tokenId, address _owner) internal returns 
        (uint256 _tokensToSend0, uint256 _tokensToSend1) {

        LimitOrder storage limitOrder = limitOrders[_tokenId];
        require(limitOrder.processed > 0);

        // TODO hidden gem, collect the liquidity fees for all pools

        (_tokensToSend0, _tokensToSend1) =
            limitOrder.pool.collect(
                address(this),
                limitOrder.tickLower,
                limitOrder.tickUpper,
                _toUint128(limitOrder.tokensOwed0),
                _toUint128(limitOrder.tokensOwed1)
            );

        require(_tokensToSend0 > 0 || _tokensToSend1 > 0);

        // refund KROM
        uint256 payment = limitOrder.monitor.batchPayment(
            limitOrder.batchId
        );

        if (limitOrder.serviceFeePaid > payment) {

            uint256 balance = funding[_owner];
            uint256 _amountToTopUp = limitOrder.serviceFeePaid.sub(payment);

            balance = balance.add(_amountToTopUp);
            funding[_owner] = balance;

            // top-up from the monitor
            TransferHelper.safeTransferFrom(
                address(KROM),
                address(limitOrder.monitor),
                address(this),
                _amountToTopUp
            );
        }

        _transferToOwner(limitOrder.pool.token0(), _tokensToSend0, _owner);
        _transferToOwner(limitOrder.pool.token1(), _tokensToSend1, _owner);

        // remove information related to tokenId
        delete limitOrders[_tokenId];
        _burn(_tokenId);

        emit LimitOrderCollected(_owner, _tokenId, _tokensToSend0, _tokensToSend1, payment);
    }

    function _selectMonitor() internal returns (IOrderMonitor _monitor) {

        uint256 monitorLength = monitors.length;
        require(monitorLength > 0);

        uint256 _selectedIndex = nextMonitor == monitorLength
            ? 0
            : nextMonitor;

        _monitor = monitors[_selectedIndex];
        nextMonitor = _selectedIndex.add(1);
    }

    /// @dev Casts uint256 to uint128 with overflow check.
    function _toUint128(uint256 x) internal pure returns (uint128) {
        assert(x <= type(uint128).max);
        return uint128(x);
    }

    /// @dev Approve transfer to position manager
    function _approveAndTransferToUniswap(address _recipient, 
        address _token, uint256 _amount, address _owner) private {

        if (_amount > 0) {
            // transfer tokens to contract
            if (_token == address(WETH)) {
                // if _token is WETH --> wrap it first
                WETH.deposit{value: _amount}();
                WETH.transfer(_recipient, _amount);
            } else {
                TransferHelper.safeTransferFrom(_token, _owner, _recipient, _amount);
            }
        }
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


    function _removeLiquidity(
        IUniswapV3Pool pool,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    )
    internal
    returns (
        uint256 amount0,
        uint256 amount1
    ) {

        if (liquidity > 0) {
            (amount0, amount1) = pool.burn(tickLower, tickUpper, liquidity);
        }
    }

    function _blockNumber() internal view returns (uint256) {
        return block.number;
    }

    function isAuthorizedForToken(uint256 tokenId) internal view {
        require(_isApprovedOrOwner(msg.sender, tokenId));
    }

    // Function to receive Ether. msg.data must be empty
    receive() external payable {}

    // Fallback function is called when msg.data is not empty
    fallback() external payable {}
}