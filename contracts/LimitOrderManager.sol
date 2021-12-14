// SPDX-License-Identifier: MIT

pragma solidity >=0.7.5;
pragma abicoder v2;

import "@openzeppelin/contracts/math/SafeMath.sol";
import '@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol';

import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";
import "@uniswap/v3-periphery/contracts/libraries/PoolAddress.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3MintCallback.sol";
import '@uniswap/v3-core/contracts/libraries/FixedPoint128.sol';
import '@uniswap/v3-core/contracts/libraries/FullMath.sol';

import "@uniswap/v3-periphery/contracts/libraries/CallbackValidation.sol";
import "@uniswap/v3-periphery/contracts/interfaces/external/IWETH9.sol";

import "./interfaces/IOrderMonitor.sol";
import "./interfaces/IOrderManager.sol";
import "./Multicall.sol";
import "./UniswapUtils.sol";
import "./WETHExtended.sol";

/// @title  LimitOrderManager
contract LimitOrderManager is
    IOrderManager,
    ERC721Upgradeable,
    IUniswapV3MintCallback,
    Multicall {

    using SafeMath for uint256;

    uint256 public constant PROTOCOL_FEE_MULTIPLIER = 100000;

    struct LimitOrder {
        IUniswapV3Pool pool;
        IOrderMonitor monitor;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 opened;
        uint256 processed;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
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
        uint256 tokensOwed0, uint256 tokensOwed1);

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

    /// @dev controller address; could be DAO
    address public controller;

    /// @dev monitor pool
    IOrderMonitor[] public monitors;

    /// @dev wrapper ETH
    IWETH9 public WETH;

    /// @dev simple WETH adapter
    WETHExtended public WETHExt;

    /// @dev univ3 factory
    IUniswapV3Factory public factory;

    /// @dev krom token
    IERC20 public KROM;

    /// @dev address where the protocol fee is sent
    address public feeAddress;

    /// @dev estimated gas usage when monitoring L.O, including a margin as well
    uint256 public override gasUsageMonitor;

    /// @dev last monitor index + 1 ; always > 0
    uint256 public nextMonitor;

    /// @dev The ID of the next token that will be minted. Skips 0
    uint176 private nextId;

    /// @dev protocol fee applied on top of monitor gas usage
    uint32 public protocolFee;

    /// @notice Initializes the smart contract instead of a constructorr
    /// @param  _factory univ3 factory
    /// @param  _WETH wrapped ETH
    /// @param  _WETHExt adapter
    /// @param  _KROM kromatika token
    /// @param  _feeAddress protocol fee address
    /// @param  _gasUsageMonitor estimated gas usage of monitors
    /// @param  _protocolFee charged fee
    function initialize(
            IUniswapV3Factory _factory,
            IWETH9 _WETH,
            WETHExtended _WETHExt,
            IERC20 _KROM,
            address _feeAddress,
            uint256 _gasUsageMonitor,
            uint32  _protocolFee
    ) public initializer {

        factory = _factory;
        WETH = _WETH;
        WETHExt = _WETHExt;
        KROM = _KROM;

        gasUsageMonitor = _gasUsageMonitor;
        protocolFee = _protocolFee;
        feeAddress = _feeAddress;

        nextId = 1;
        controller = msg.sender;

        ERC721Upgradeable.__ERC721_init("Kromatika Position", "KROM-POS");
    }

    function placeLimitOrder(LimitOrderParams calldata params)
        public payable override virtual returns (
            uint256 _tokenId
        ) {

        int24 _tickLower;
        int24 _tickUpper;
        uint128 _liquidity;
        uint128 _orderType;
        IUniswapV3Pool _pool;

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
        _pool.mint(
            address(this),
            _tickLower,
            _tickUpper,
            _liquidity,
            abi.encode(MintCallbackData({poolKey: _poolKey, payer: msg.sender}))
        );

        _mint(msg.sender, (_tokenId = nextId++));

        {

            activeOrders[msg.sender] = activeOrders[msg.sender].add(1);
            IOrderMonitor _monitor = _selectMonitor();

            (, uint256 _feeGrowthInside0LastX128, uint256 _feeGrowthInside1LastX128, , ) = _pool.positions(
                PositionKey.compute(address(this), _tickLower, _tickUpper)
            );

            // Create a limitOrder
            LimitOrder memory newLimitOrder = LimitOrder({
                pool: _pool,
                monitor: _monitor,
                tickLower: _tickLower,
                tickUpper: _tickUpper,
                liquidity: _liquidity,
                opened: _blockNumber(),
                processed: 0,
                feeGrowthInside0LastX128: _feeGrowthInside0LastX128,
                feeGrowthInside1LastX128: _feeGrowthInside1LastX128,
                tokensOwed0: params._amount0,
                tokensOwed1: params._amount1
            });

            limitOrders[_tokenId] = newLimitOrder;

            _monitor.startMonitor(_tokenId);
        }

        emit LimitOrderCreated(
            msg.sender,
            _tokenId,
            _orderType,
            params._sqrtPriceX96,
            params._amount0,
            params._amount1
        );
    }

    function processLimitOrder(
        uint256 _tokenId, uint256 _batchId,
        uint256 _serviceFeePaid, uint256 _monitorFeePaid
    ) external override
        returns (uint128 _amount0, uint128 _amount1) {

        LimitOrder storage limitOrder = limitOrders[_tokenId];
        require(msg.sender == address(limitOrder.monitor));
        require(limitOrder.processed == 0);

        // remove liqudiity
        (_amount0, _amount1) = _removeLiquidity(limitOrder);

        limitOrder.processed = _blockNumber();
        limitOrder.tokensOwed0 = _amount0;
        limitOrder.tokensOwed1 = _amount1;
        limitOrder.liquidity = 0;

        address _owner = ownerOf(_tokenId);

        // update balance
        uint256 balance = funding[_owner];
        // send service fee for this order to the monitor based on the target gas price set
        uint256 _protocolFeePaid = _serviceFeePaid.sub(_monitorFeePaid);
        // reduce balance by the service fee
        balance = balance.sub(_serviceFeePaid);
        funding[_owner] = balance;

        // reduce activeOrders
        activeOrders[_owner] = activeOrders[_owner].sub(1);

        // collect the funds
        _collect(
            _tokenId,
            limitOrder.pool,
            limitOrder.tickLower,
            limitOrder.tickUpper,
            limitOrder.tokensOwed0,
            limitOrder.tokensOwed1,
            _owner
        );

        // send fees to monitor and protocol
        _transferTokenTo(address(KROM), _monitorFeePaid, msg.sender);
        _transferTokenTo(address(KROM), _protocolFeePaid, feeAddress);

        emit LimitOrderProcessed(msg.sender, _tokenId, _batchId, _serviceFeePaid);
    }


    function cancelLimitOrder(uint256 _tokenId) external returns (
        uint256 _amount0, uint256 _amount1
    ) {

        isAuthorizedForToken(_tokenId);

        LimitOrder storage limitOrder = limitOrders[_tokenId];
        require(limitOrder.processed == 0);

        (_amount0, _amount1) = _removeLiquidity(limitOrder);

        activeOrders[msg.sender] = activeOrders[msg.sender].sub(1);

        // burn the token
        _burn(_tokenId);

        // stop monitor
        limitOrder.monitor.stopMonitor(_tokenId);
        // collect the funds
        _collect(
            _tokenId,
            limitOrder.pool,
            limitOrder.tickLower,
            limitOrder.tickUpper,
            limitOrder.tokensOwed0,
            limitOrder.tokensOwed1,
            msg.sender
        );

        delete limitOrders[_tokenId];
        emit LimitOrderCancelled(msg.sender, _tokenId, _amount0, _amount1);
    }

    function burn(uint256 _tokenId) external {

        isAuthorizedForToken(_tokenId);
        // remove information related to tokenId
        require(limitOrders[_tokenId].processed > 0);

        delete limitOrders[_tokenId];
        _burn(_tokenId);
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
        (uint256 reservedServiceFee,) = estimateServiceFee(
            targetGasPrice[msg.sender],
            activeOrders[msg.sender],
            msg.sender
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

    function canProcess(uint256 _tokenId, uint256 _gasPrice) external view override
    returns (bool underfunded, uint256 _serviceFee, uint256 _monitorFee) {

        LimitOrder storage limitOrder = limitOrders[_tokenId];

        address _owner = ownerOf(_tokenId);
        (underfunded, , _serviceFee, _monitorFee) = isUnderfunded(_owner);
        if (underfunded || targetGasPrice[_owner] < _gasPrice) {
            underfunded = false;
        } else {
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
                underfunded = true;
            } else if (
                limitOrder.tokensOwed0 > 0 && amount0 == 0 &&
                limitOrder.tokensOwed1 == 0 && amount1 > 0
            ) {
                underfunded = true;
            } else { underfunded = false;}
        }
    
    }

    function isUnderfunded(address _owner) public view returns (
        bool underfunded, uint256 amount, uint256 _serviceFee, uint256 _monitorFee
    ) {
        uint256 _targetGasPrice = targetGasPrice[_owner];
        if (_targetGasPrice > 0) {
            (_serviceFee,_monitorFee)= estimateServiceFee(
                _targetGasPrice, 1, _owner
            );
            uint256 reservedServiceFee = _serviceFee.mul(activeOrders[_owner]);
            uint256 balance = funding[_owner];

            if (reservedServiceFee > balance) {
                underfunded = true;
                amount = reservedServiceFee.sub(balance);
            }
        } else {
            underfunded = true;
        }
    }

    function setMonitors(IOrderMonitor[] calldata _newMonitors) external {

        isAuthorizedController();
        require(_newMonitors.length > 0);
        monitors = _newMonitors;
    }

    function addMonitor(IOrderMonitor _newMonitor) external {
        isAuthorizedController();
        monitors.push(_newMonitor);
    }

    function setProtocolFee(uint32 _protocolFee) external {
        isAuthorizedController();
        require(_protocolFee <= PROTOCOL_FEE_MULTIPLIER, "INVALID_FEE");
        protocolFee = _protocolFee;
    }

    function setGasUsageMonitor(uint256 _gasUsageMonitor) external {
        isAuthorizedController();
        gasUsageMonitor = _gasUsageMonitor;
    }

    function changeController(address _controller) external {
        isAuthorizedController();
        controller = _controller;
    }

    function monitorsLength() external view returns (uint256) {
        return monitors.length;
    }

    function quoteKROM(uint256 _weiAmount) public view override returns (uint256 quote) {

        return UniswapUtils.quoteKROM(
            factory,
            address(WETH),
            address(KROM),
            _weiAmount
        );
    }

    function serviceFee(address _owner) public view returns (uint256 _serviceFee) {

        (_serviceFee,) = estimateServiceFee(
            targetGasPrice[_owner],
            activeOrders[_owner],
            _owner
        );
    }

    function estimateServiceFee(
        uint256 _targetGasPrice,
        uint256 _noOrders,
        address _owner) public view virtual
    returns (uint256 _serviceFee, uint256 _monitorFee) {

        _monitorFee = quoteKROM(
            gasUsageMonitor.mul(_targetGasPrice).mul(_noOrders)
        );

        _serviceFee = _monitorFee
        .mul(PROTOCOL_FEE_MULTIPLIER.add(protocolFee))
        .div(PROTOCOL_FEE_MULTIPLIER);
    }

    function _collect(
        uint256 _tokenId,
        IUniswapV3Pool _pool,
        int24 _tickLower,
        int24 _tickUpper,
        uint128 _tokensOwed0,
        uint128 _tokensOwed1,
        address _owner
    ) internal returns
        (uint256 _tokensToSend0, uint256 _tokensToSend1) {

        (_tokensToSend0, _tokensToSend1) =
            _pool.collect(
                address(this),
                 _tickLower,
                _tickUpper,
                _tokensOwed0,
                _tokensOwed1
            );

        require(_tokensToSend0 > 0 || _tokensToSend1 > 0);

        _transferTokenTo(_pool.token0(), _tokensToSend0, _owner);
        _transferTokenTo(_pool.token1(), _tokensToSend1, _owner);

        emit LimitOrderCollected(_owner, _tokenId, _tokensToSend0, _tokensToSend1);
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

    function _transferTokenTo(address _token, uint256 _amount, address _to) private {
        if (_amount > 0) {
            if (_token == address(WETH)) {
                // if token is WETH, withdraw and send back ETH
                WETH.transfer(address(WETHExt), _amount);
                WETHExt.withdraw(_amount, _to, WETH);
            } else {
                TransferHelper.safeTransfer(_token, _to, _amount);
            }
        }
    }


    function _removeLiquidity(LimitOrder storage limitOrder)
    internal
    returns (
        uint128 tokensOwed0,
        uint128 tokensOwed1
    ) {

        if (limitOrder.liquidity > 0) {
            (uint256 amount0, uint256 amount1) = limitOrder.pool.burn(
                limitOrder.tickLower, limitOrder.tickUpper, limitOrder.liquidity
            );

            bytes32 positionKey = PositionKey.compute(address(this), limitOrder.tickLower, limitOrder.tickUpper);
            (, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128, , ) = limitOrder.pool.positions(positionKey);

            tokensOwed0 = uint128(amount0) + uint128(
                FullMath.mulDiv(
                    feeGrowthInside0LastX128 - limitOrder.feeGrowthInside0LastX128,
                    limitOrder.liquidity,
                    FixedPoint128.Q128
                )
            );

            tokensOwed1 = uint128(amount1) + uint128(
                FullMath.mulDiv(
                    feeGrowthInside1LastX128 - limitOrder.feeGrowthInside1LastX128,
                    limitOrder.liquidity,
                    FixedPoint128.Q128
                )
            );
        }
    }

    function _blockNumber() internal view returns (uint256) {
        return block.number;
    }

    function isAuthorizedForToken(uint256 tokenId) internal view {
        require(_isApprovedOrOwner(msg.sender, tokenId));
    }

    function isAuthorizedController() internal view {
        require(msg.sender == controller);
    }

    // Function to receive Ether. msg.data must be empty
    receive() external payable {}

    // Fallback function is called when msg.data is not empty
    fallback() external payable {}
}