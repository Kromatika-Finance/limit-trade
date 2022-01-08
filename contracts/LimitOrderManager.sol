// SPDX-License-Identifier: GPL-3.0-or-later

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
import "@uniswap/v3-periphery/contracts/libraries/PositionKey.sol";

import "@uniswap/v3-periphery/contracts/libraries/CallbackValidation.sol";
import "@uniswap/v3-periphery/contracts/interfaces/external/IWETH9.sol";

import "./interfaces/IOrderMonitor.sol";
import "./interfaces/IOrderManager.sol";
import "./interfaces/IUniswapUtils.sol";

import "./SelfPermit.sol";
import "./Multicall.sol";
import "./WETHExtended.sol";

/// @title  LimitOrderManager
contract LimitOrderManager is
    IOrderManager,
    ERC721Upgradeable,
    IUniswapV3MintCallback,
    Multicall,
    SelfPermit {

    using SafeMath for uint256;

    uint256 public constant PROTOCOL_FEE_MULTIPLIER = 100000;

    struct LimitOrder {
        address pool;
        uint32 monitor;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        bool processed;
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
    event LimitOrderProcessed(address indexed monitor, uint256 indexed tokenId, uint256 serviceFeePaid);

    /// @dev fired when an order is cancelled
    event LimitOrderCancelled(address indexed owner, uint256 indexed tokenId, uint256 amount0, uint256 amount1);

    /// @dev fired when an order is collected
    event LimitOrderCollected(address indexed owner, uint256 indexed tokenId,
        uint256 tokensOwed0, uint256 tokensOwed1);

    /// @dev fired when a new funding is made
    event FundingAdded(address indexed from, uint256 amount);

    /// @dev fired when funding is withdrawn
    event FundingWithdrawn(address indexed from, uint256 amount);

    /// @dev when gas usage was changed
    event GasUsageMonitorChanged(address from, uint256 newValue);

    /// @dev when protocol fee was changed
    event ProtocolFeeChanged(address from, uint32 newValue);

    /// @dev when protocol address was changed
    event ProtocolAddressChanged(address from, address newValue);

    /// @dev when controller was changed
    event ControllerChanged(address from, address newValue);

    /// @dev funding
    mapping(address => uint256) public override funding;

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

    /// @dev wrapper extended
    WETHExtended public WETHExt;

    /// @dev utils
    IUniswapUtils public utils;

    /// @dev univ3 factory
    IUniswapV3Factory public factory;

    /// @dev krom token
    IERC20 public KROM;

    /// @dev address where the protocol fee is sent
    address public override feeAddress;

    /// @dev protocol fee applied on top of monitor gas usage
    uint32 public protocolFee;

    /// @dev estimated gas usage when monitoring L.O, including a margin as well
    uint256 public gasUsageMonitor;

    /// @dev The ID of the next token that will be minted. Skips 0
    uint176 private nextId;

    /// @dev last monitor index + 1 ; always > 0
    uint32 public nextMonitor;

    /// @notice Initializes the smart contract instead of a constructorr
    /// @param  _factory univ3 factory
    /// @param  _WETH wrapped ETH
    /// @param  _utils limit manager utils
    /// @param  _KROM kromatika token
    /// @param  _feeAddress protocol fee address
    /// @param  _gasUsageMonitor estimated gas usage of monitors
    /// @param  _protocolFee charged fee
    function initialize(
            IUniswapV3Factory _factory,
            IWETH9 _WETH,
            WETHExtended _WETHExtended,
            IUniswapUtils _utils,
            IERC20 _KROM,
            address _feeAddress,
            uint256 _gasUsageMonitor,
            uint32  _protocolFee
    ) public initializer {

        factory = _factory;
        utils = _utils;
        WETH = _WETH;
        KROM = _KROM;
        WETHExt = _WETHExtended;

        gasUsageMonitor = _gasUsageMonitor;
        protocolFee = _protocolFee;
        feeAddress = _feeAddress;

        nextId = 1;
        controller = msg.sender;

        ERC721Upgradeable.__ERC721_init("Kromatika Position", "KROM-POS");

        emit GasUsageMonitorChanged(msg.sender, _gasUsageMonitor);
        emit ProtocolFeeChanged(msg.sender, _protocolFee);
        emit ProtocolAddressChanged(msg.sender, _feeAddress);
    }

    function placeLimitOrder(LimitOrderParams calldata params)
        public payable override virtual returns (
            uint256 _tokenId
        ) {

        require(params._token0 < params._token1);

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

        (_tickLower, _tickUpper, _liquidity, _orderType) = utils.calculateLimitTicks(
            _pool,
            params._sqrtPriceX96,
            params._amount0,
            params._amount1
        );
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
            uint32 _selectedIndex = _selectMonitor();
            nextMonitor = _selectedIndex + 1;

            (, uint256 _feeGrowthInside0LastX128, uint256 _feeGrowthInside1LastX128, , ) = _pool.positions(
                PositionKey.compute(address(this), _tickLower, _tickUpper)
            );

            limitOrders[_tokenId] = LimitOrder({
                pool: _poolAddress,
                monitor: _selectedIndex,
                tickLower: _tickLower,
                tickUpper: _tickUpper,
                liquidity: _liquidity,
                processed: false,
                feeGrowthInside0LastX128: _feeGrowthInside0LastX128,
                feeGrowthInside1LastX128: _feeGrowthInside1LastX128,
                tokensOwed0: params._amount0,
                tokensOwed1: params._amount1
            });

            monitors[_selectedIndex].startMonitor(_tokenId);
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
        uint256 _tokenId,
        uint256 _serviceFeePaid,
        uint256
    ) external override
        returns (uint128 _amount0, uint128 _amount1) {

        LimitOrder storage limitOrder = limitOrders[_tokenId];
        require(msg.sender == address(monitors[limitOrder.monitor]));
        require(!limitOrder.processed);

        // remove liqudiity
        (_amount0, _amount1) = _removeLiquidity(
            IUniswapV3Pool(limitOrder.pool),
            limitOrder.tickLower,
            limitOrder.tickUpper,
            limitOrder.liquidity,
            limitOrder.feeGrowthInside0LastX128,
            limitOrder.feeGrowthInside1LastX128
        );

        limitOrder.liquidity = 0;
        limitOrder.processed = true;
        limitOrder.tokensOwed0 = _amount0;
        limitOrder.tokensOwed1 = _amount1;

        address _owner = ownerOf(_tokenId);

        // update balance
        uint256 balance = funding[_owner];
        // reduce balance by the service fee
        balance = balance.sub(_serviceFeePaid);
        funding[_owner] = balance;

        // reduce activeOrders
        activeOrders[_owner] = activeOrders[_owner].sub(1);

        // collect the funds
        _collect(
            _tokenId,
            IUniswapV3Pool(limitOrder.pool),
            limitOrder.tickLower,
            limitOrder.tickUpper,
            limitOrder.tokensOwed0,
            limitOrder.tokensOwed1,
            _owner
        );

        // send fees to monitor and protocol
        _transferTokenTo(address(KROM), _serviceFeePaid, msg.sender);

        emit LimitOrderProcessed(msg.sender, _tokenId, _serviceFeePaid);
    }


    function cancelLimitOrder(uint256 _tokenId) external returns (
        uint256 _amount0, uint256 _amount1
    ) {

        isAuthorizedForToken(_tokenId);

        LimitOrder storage limitOrder = limitOrders[_tokenId];
        require(!limitOrder.processed);

        (_amount0, _amount1) = _removeLiquidity(
            IUniswapV3Pool(limitOrder.pool),
            limitOrder.tickLower,
            limitOrder.tickUpper,
            limitOrder.liquidity,
            limitOrder.feeGrowthInside0LastX128,
            limitOrder.feeGrowthInside1LastX128
        );

        activeOrders[msg.sender] = activeOrders[msg.sender].sub(1);

        // burn the token
        _burn(_tokenId);

        // stop monitor
        monitors[limitOrder.monitor].stopMonitor(_tokenId);
        // collect the funds
        _collect(
            _tokenId,
            IUniswapV3Pool(limitOrder.pool),
            limitOrder.tickLower,
            limitOrder.tickUpper,
            _toUint128(_amount0),
            _toUint128(_amount1),
            msg.sender
        );

        delete limitOrders[_tokenId];
        emit LimitOrderCancelled(msg.sender, _tokenId, _amount0, _amount1);
    }

    function burn(uint256 _tokenId) external {

        isAuthorizedForToken(_tokenId);
        // remove information related to tokenId
        require(limitOrders[_tokenId].processed);

        delete limitOrders[_tokenId];
        _burn(_tokenId);
    }

    function addFunding(uint256 _amount) external {

        funding[msg.sender] = funding[msg.sender].add(_amount);
        TransferHelper.safeTransferFrom(address(KROM), msg.sender, address(this), _amount);
        emit FundingAdded(msg.sender, _amount);
    }

    function withdrawFunding(uint256 _amount) external {

        uint256 balance = funding[msg.sender];

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
        bool processed,
        uint256 tokensOwed0,
        uint256 tokensOwed1
    )
    {
        LimitOrder memory limitOrder = limitOrders[tokenId];
        require(limitOrder.pool != address(0));
        IUniswapV3Pool _pool = IUniswapV3Pool(limitOrder.pool);
        return (
            ownerOf(tokenId),
            _pool.token0(),
            _pool.token1(),
            _pool.fee(),
            limitOrder.tickLower,
            limitOrder.tickUpper,
            limitOrder.liquidity,
            limitOrder.processed,
            limitOrder.tokensOwed0,
            limitOrder.tokensOwed1
        );
    }

    function canProcess(uint256 _tokenId, uint256 _gasPrice) external override
    returns (bool underfunded, uint256 _serviceFee, uint256 _monitorFee) {

        LimitOrder storage limitOrder = limitOrders[_tokenId];

        address _owner = ownerOf(_tokenId);
        (underfunded, , _serviceFee, _monitorFee) = _isUnderfunded(_owner, _gasPrice);
        if (underfunded) {
            underfunded = false;
        } else {
            (uint256 amount0, uint256 amount1) =
                utils._amountsForLiquidity(
                    IUniswapV3Pool(limitOrder.pool),
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

    function isUnderfunded(address _owner, uint256 _targetGasPrice) public returns (
        bool underfunded, uint256 amount, uint256 _serviceFee, uint256 _monitorFee
    ) {
        return _isUnderfunded(_owner, _targetGasPrice);
    }

    function _isUnderfunded(address _owner, uint256 _targetGasPrice) internal returns (
        bool underfunded, uint256 amount, uint256 _serviceFee, uint256 _monitorFee
    ) {
        if (_targetGasPrice > 0) {
            // estimate for 1 limit trade
            (_serviceFee,_monitorFee) = _estimateServiceFee(
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
        emit ProtocolFeeChanged(msg.sender, _protocolFee);
    }

    function setGasUsageMonitor(uint256 _gasUsageMonitor) external {
        isAuthorizedController();
        gasUsageMonitor = _gasUsageMonitor;
        emit GasUsageMonitorChanged(msg.sender, _gasUsageMonitor);
    }

    function changeController(address _controller) external {
        isAuthorizedController();
        controller = _controller;
        emit ControllerChanged(msg.sender, _controller);
    }

    function monitorsLength() external view returns (uint256) {
        return monitors.length;
    }

    function quoteKROM(uint256 _weiAmount) public override returns (uint256 quote) {

        return utils.quoteKROM(
            factory,
            address(WETH),
            address(KROM),
            _weiAmount
        );
    }

    function serviceFee(address _owner, uint256 _targetGasPrice)
        public returns (uint256 _serviceFee) {

        (_serviceFee,) = _estimateServiceFee(
            _targetGasPrice,
            activeOrders[_owner],
            _owner
        );
    }

    function estimateServiceFee(
        uint256 _targetGasPrice,
        uint256 _noOrders,
        address _owner) public virtual
    returns (uint256 _serviceFee, uint256 _monitorFee) {

        return _estimateServiceFee(_targetGasPrice, _noOrders, _owner);
    }

    function _estimateServiceFee(
        uint256 _targetGasPrice,
        uint256 _noOrders,
        address) internal virtual
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

    function _selectMonitor() internal view returns (uint32 _selectedIndex) {

        uint256 monitorLength = monitors.length;
        require(monitorLength > 0);

        _selectedIndex = nextMonitor == monitorLength
            ? 0
            : nextMonitor;
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
                require(WETH.transfer(_recipient, _amount));
            } else {
                TransferHelper.safeTransferFrom(_token, _owner, _recipient, _amount);
            }
        }
    }

    function _transferTokenTo(address _token, uint256 _amount, address _to) private {
        if (_amount > 0) {
            if (_token == address(WETH)) {
                // if token is WETH, withdraw and send back ETH
                require(WETH.transfer(address(WETHExt), _amount));
                WETHExt.withdraw(_amount, _to, WETH);
            } else {
                TransferHelper.safeTransfer(_token, _to, _amount);
            }
        }
    }


    function _removeLiquidity(
        IUniswapV3Pool _pool,
        int24 _tickLower,
        int24 _tickUpper,
        uint128 _liquidity,
        uint256 _feeGrowthInside0LastX128,
        uint256 _feeGrowthInside1LastX128
    )
    internal
    returns (
        uint128 tokensOwed0,
        uint128 tokensOwed1
    ) {

        if (_liquidity > 0) {
            (uint256 amount0, uint256 amount1) = _pool.burn(
                _tickLower, _tickUpper, _liquidity
            );

            bytes32 positionKey = PositionKey.compute(address(this), _tickLower, _tickUpper);
            (, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128, , ) = _pool.positions(positionKey);

            tokensOwed0 = uint128(amount0) + uint128(
                FullMath.mulDiv(
                    feeGrowthInside0LastX128 - _feeGrowthInside0LastX128,
                    _liquidity,
                    FixedPoint128.Q128
                )
            );

            tokensOwed1 = uint128(amount1) + uint128(
                FullMath.mulDiv(
                    feeGrowthInside1LastX128 - _feeGrowthInside1LastX128,
                    _liquidity,
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