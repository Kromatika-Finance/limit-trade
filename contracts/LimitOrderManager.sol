// SPDX-License-Identifier: MIT

pragma solidity >=0.7.5;
pragma abicoder v2;

import "@openzeppelin/contracts/math/SafeMath.sol";
import '@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol';
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";
import "@uniswap/v3-periphery/contracts/libraries/PoolAddress.sol";
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

    uint256 private constant MARGIN_GAS_USAGE_MULTIPLIER = 100000;

    uint256 private constant MONITOR_GAS_USAGE = 600000;

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
        uint256 serviceFeePaid;
        uint256 tokensOwed0;
        uint256 tokensOwed1;
    }

     struct MintCallbackData {
        PoolAddress.PoolKey poolKey;
        address payer;
    }

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

    /// @dev target gas price
    event TargetGasPriceSet(address indexed from, uint256 gasPrice);

    /// @dev funding
    mapping(address => uint256) public override funding;

    /// @dev gas price
    mapping(address => uint256) public targetGasPrice;

    /// @dev active orders
    mapping(address => uint256) public activeOrders;

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

    /// @dev gas usage multiplier
    uint256 public marginGasUsageMultiplier;

    /// @dev last monitor index + 1 ; always > 0
    uint256 public nextMonitor;

    /// @dev The ID of the next token that will be minted. Skips 0
    uint176 private nextId;

    /// @notice Initializes the smart contract instead of a constructorr
    /// @param _factory univ3 factory
    /// @param _WETH wrapped ETH
    /// @param _KROM kromatika token
    /// @param _marginGasUsageMultiplier gas usage of the order monitor
    function initialize(IUniswapV3Factory _factory,
            IWETH9 _WETH,
            IERC20 _KROM,
            uint256 _marginGasUsageMultiplier) public initializer {

        factory = _factory;
        WETH = _WETH;
        KROM = _KROM;

        marginGasUsageMultiplier = _marginGasUsageMultiplier;
        nextId = 1;

        OwnableUpgradeable.__Ownable_init();
        ERC721Upgradeable.__ERC721_init("Kromatika Position", "KROM-POS");
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

        address _owner = ownerOf(_tokenId);
        // send service fee for this order to the monitor based on the target gas price set
        _serviceFeePaid = estimateServiceFee(targetGasPrice[_owner], 1);
        require(_serviceFeePaid > 0);

        limitOrder.serviceFeePaid = _serviceFeePaid;

        // update balance
        uint256 balance = funding[_owner];

        // reduce balance
        balance = balance.sub(_serviceFeePaid);
        funding[_owner] = balance;

        // reduce activeOrders
        activeOrders[_owner] = activeOrders[_owner].sub(1);

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

        activeOrders[msg.sender] = activeOrders[msg.sender].sub(1);

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

    function setTargetGasPrice(uint256 _targetGasPrice) external {

        require(_targetGasPrice > 0);

        targetGasPrice[msg.sender] = _targetGasPrice;
        emit TargetGasPriceSet(msg.sender, _targetGasPrice);
    }

    function withdrawFunding(uint256 _amount) external {

        uint256 balance = funding[msg.sender];
        uint256 reservedServiceFee = estimateServiceFee(
            targetGasPrice[msg.sender],
            activeOrders[msg.sender]
        );
        require(balance >= reservedServiceFee);

        balance = balance.sub(_amount);
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
            limitOrder.tokensOwed0,
            limitOrder.tokensOwed1
        );
    }

    function canProcess(uint256 _tokenId, uint256 _gasPrice) external view override returns (bool) {

        LimitOrder storage limitOrder = limitOrders[_tokenId];

        address _owner = ownerOf(_tokenId);
        (bool underfunded,) = isUnderfunded(_owner);
        if (underfunded || targetGasPrice[_owner] < _gasPrice) {
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
        uint256 _targetGasPrice = targetGasPrice[_owner];
        if (_targetGasPrice > 0) {
            uint256 reservedServiceFee = estimateServiceFee(
                _targetGasPrice,
                activeOrders[_owner]
            );
            uint256 balance = funding[_owner];

            if (reservedServiceFee > balance) {
                underfunded = true;
                amount = reservedServiceFee.sub(balance);
            }
        } else {
            underfunded = true;
        }
    }

    function setMonitors(IOrderMonitor[] calldata _newMonitors) external onlyOwner {

        require(_newMonitors.length > 0);
        monitors = _newMonitors;
    }

    function monitorsLength() external view returns (uint256) {
        return monitors.length;
    }

    function setMarginGasUsageMultiplier(uint256 _marginGasUsageMultiplier) external onlyOwner {

        require(_marginGasUsageMultiplier <= MARGIN_GAS_USAGE_MULTIPLIER, "INVALID_FEE");
        marginGasUsageMultiplier = _marginGasUsageMultiplier;
    }

    function quoteKROM(uint256 _weiAmount) public view override returns (uint256 quote) {

        return UniswapUtils.quoteKROM(
            factory,
            address(WETH),
            address(KROM),
            _weiAmount
        );
    }

    function serviceFee(address _owner) public view returns (uint256) {

        return estimateServiceFee(
            targetGasPrice[_owner],
            activeOrders[_owner]
        );
    }

    function estimateServiceFee(
        uint256 _targetGasPrice,
        uint256 _noOrders) public view returns (uint256) {

        return quoteKROM(
            MONITOR_GAS_USAGE.mul(_targetGasPrice).mul(_noOrders)
            .mul(MARGIN_GAS_USAGE_MULTIPLIER.add(marginGasUsageMultiplier))
            .div(MARGIN_GAS_USAGE_MULTIPLIER)
        );
    }

    function _createLimitOrder(
        uint256 _tokenId, IUniswapV3Pool _pool,
        LimitOrderParams memory params,
        int24 _tickLower, int24 _tickUpper, uint128 _liquidity, uint128 _orderType, 
        address _owner) internal {

        activeOrders[_owner] = activeOrders[_owner].add(1);
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
            serviceFeePaid: 0,
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

        // TODO collect the liquidity fees for all pools

        (_tokensToSend0, _tokensToSend1) =
            limitOrder.pool.collect(
                address(this),
                limitOrder.tickLower,
                limitOrder.tickUpper,
                _toUint128(limitOrder.tokensOwed0),
                _toUint128(limitOrder.tokensOwed1)
            );

        require(_tokensToSend0 > 0 || _tokensToSend1 > 0);

        // refund
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