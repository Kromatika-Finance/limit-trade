// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.7.6;
pragma abicoder v2;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/SafeCast.sol";
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
    using SafeCast for uint256;

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

    /// @dev native transfer
    bool nativeTransfer;

    /// @dev router address
    address public router;

    constructor () initializer {}

    /// @notice Initializes the smart contract instead of a constructor
    /// @param  _factory univ3 factory
    /// @param  _WETH wrapped ETH
    /// @param  _utils limit manager utils
    /// @param  _KROM kromatika token
    /// @param  _monitors monitors array
    /// @param  _feeAddress protocol fee address
    /// @param  _gasUsageMonitor estimated gas usage of monitors
    /// @param  _protocolFee charged fee
    function initialize(
            IUniswapV3Factory _factory,
            IWETH9 _WETH,
            WETHExtended _WETHExtended,
            IUniswapUtils _utils,
            IERC20 _KROM,
            IOrderMonitor[] calldata _monitors,
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
        monitors = _monitors;

        nextId = 1;
        controller = msg.sender;
        nativeTransfer = true;

        ERC721Upgradeable.__ERC721_init("Kromatika Position", "KROM-POS");

        emit GasUsageMonitorChanged(msg.sender, _gasUsageMonitor);
        emit ProtocolFeeChanged(msg.sender, _protocolFee);
        emit ProtocolAddressChanged(msg.sender, _feeAddress);
    }

    function placeLimitOrder(LimitOrderParams calldata params)
        public payable override virtual returns (
            uint256 _tokenId
        ) {

        require(params._token0 < params._token1, "LOM_TE");

        address _owner = _msgSender();

        uint128 _liquidity;
        IUniswapV3Pool _pool;

        PoolAddress.PoolKey memory _poolKey =
        PoolAddress.PoolKey({
            token0: params._token0,
            token1: params._token1,
            fee: params._fee
        });

        {
            address _poolAddress = PoolAddress.computeAddress(address(factory), _poolKey);
            require (_poolAddress != address(0), "LOM_PA");
            _pool = IUniswapV3Pool(_poolAddress);

            (uint160 sqrtRatioX96,, , , , , ) = _pool.slot0();
            _liquidity = LiquidityAmounts.getLiquidityForAmounts(
                sqrtRatioX96,
                TickMath.getSqrtRatioAtTick(params._tickLower),
                TickMath.getSqrtRatioAtTick(params._tickUpper),
                params._amount0,
                params._amount1
            );

            require (_liquidity > 0, "LOM_NL");
        }

        {
            (uint256 _amount0, uint256 _amount1) = _pool.mint(
                address(this),
                params._tickLower,
                params._tickUpper,
                _liquidity,
                abi.encode(MintCallbackData({poolKey: _poolKey, payer: _owner}))
            );
            require(_amount0 >= params._amount0Min && _amount1 >= params._amount1Min, 'LOM_PS');

            _mint(_owner, (_tokenId = nextId++));

            (, uint256 _feeGrowthInside0LastX128, uint256 _feeGrowthInside1LastX128, , ) = _pool.positions(
                PositionKey.compute(address(this), params._tickLower, params._tickUpper)
            );

            limitOrders[_tokenId] = LimitOrder({
                pool: address(_pool),
                monitor: 0,
                tickLower: params._tickLower,
                tickUpper: params._tickUpper,
                liquidity: _liquidity,
                processed: false,
                feeGrowthInside0LastX128: _feeGrowthInside0LastX128,
                feeGrowthInside1LastX128: _feeGrowthInside1LastX128,
                tokensOwed0: _amount0.toUint128(),
                tokensOwed1: _amount1.toUint128()
            });
        }

        emit LimitOrderCreated(
            _owner,
            _tokenId,
            0,
            params._sqrtPriceX96,
            params._amount0,
            params._amount1
        );
    }

    function processLimitOrder(
        uint256 _tokenId
    ) external override
        returns (bool) {

        bool validTrade = canProcess(_tokenId);
        if (!validTrade) {
            return false;
        }

        LimitOrder storage limitOrder = limitOrders[_tokenId];
        require(!limitOrder.processed, "LOM_PR");

        // remove liquidity
        (uint128 _amount0, uint256 _fee0, uint128 _amount1, uint256 _fee1) = _removeLiquidity(
            IUniswapV3Pool(limitOrder.pool),
            limitOrder.tickLower,
            limitOrder.tickUpper,
            limitOrder.liquidity,
            limitOrder.feeGrowthInside0LastX128,
            limitOrder.feeGrowthInside1LastX128
        );

        limitOrder.liquidity = 0;
        limitOrder.processed = true;

        address _owner = ownerOf(_tokenId);

        // collect the funds
        _collect(
            _tokenId,
            IUniswapV3Pool(limitOrder.pool),
            limitOrder.tickLower,
            limitOrder.tickUpper,
            _amount0,
            _fee0,
            _amount1,
            _fee1,
            _owner
        );

        emit LimitOrderProcessed(msg.sender, _tokenId, 0);

        return true;
    }


    function cancelLimitOrder(uint256 _tokenId) external returns (
        uint256 _amount0, uint256 _fee0, uint256 _amount1, uint256 _fee1
    ) {

        address _owner = _msgSender();
        require(_isApprovedOrOwner(_owner, _tokenId), "LOM_AT");

        LimitOrder storage limitOrder = limitOrders[_tokenId];
        require(!limitOrder.processed, "LOM_PR");
        address poolAddress = limitOrder.pool;
        int24 tickLower = limitOrder.tickLower;
        int24 tickUpper = limitOrder.tickUpper;

        (_amount0, _fee0, _amount1, _fee1) = _removeLiquidity(
            IUniswapV3Pool(poolAddress),
            tickLower,
            tickUpper,
            limitOrder.liquidity,
            limitOrder.feeGrowthInside0LastX128,
            limitOrder.feeGrowthInside1LastX128
        );

        // burn the token
        _burn(_tokenId);

        // delete lo
        delete limitOrders[_tokenId];

        // collect the funds
        _collect(
            _tokenId,
            IUniswapV3Pool(poolAddress),
            tickLower,
            tickUpper,
            _amount0.toUint128(),
            _fee0,
            _amount1.toUint128(),
            _fee1,
            _owner
        );

        emit LimitOrderCancelled(_owner, _tokenId, _amount0, _amount1);
    }

    function withdrawFunding(uint256 _amount) external {

        address _owner = _msgSender();
        uint256 balance = funding[_owner];

        balance = balance.sub(_amount);
        funding[_owner] = balance;
        TransferHelper.safeTransfer(address(KROM), _owner, _amount);
        emit FundingWithdrawn(_owner, _amount);
    }

    function uniswapV3MintCallback(
        uint256 amount0Owed,
        uint256 amount1Owed,
        bytes calldata data
    ) external override {
        MintCallbackData memory decoded = abi.decode(data, (MintCallbackData));
        CallbackValidation.verifyCallback(address(factory), decoded.poolKey);

        address _owner = _msgSender();

        _approveAndTransferToUniswap(_owner, decoded.poolKey.token0, amount0Owed, decoded.payer);
        _approveAndTransferToUniswap(_owner, decoded.poolKey.token1, amount1Owed, decoded.payer);
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

    function canProcess(uint256 _tokenId) public view override
    returns (bool validLimitOrder) {

        LimitOrder storage limitOrder = limitOrders[_tokenId];

        if (!_exists(_tokenId) || limitOrder.pool == address(0)) {
            return false;
        }

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
            validLimitOrder = true;
        } else if (
            limitOrder.tokensOwed0 > 0 && amount0 == 0 &&
            limitOrder.tokensOwed1 == 0 && amount1 > 0
        ) {
            validLimitOrder = true;
        } else { validLimitOrder = false;}
    }

    function getTokenIdsLength() external view override returns(
        uint256
    ) {
        return nextId;
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

    function changeRouter(address _router) external {
        isAuthorizedController();
        router = _router;
    }

    function _msgSender() internal virtual override view returns (address ret) {
        if (msg.data.length >= 24 && router == msg.sender) {
            // At this point we know that the sender is a trusted forwarder,
            // so we trust that the last bytes of msg.data are the verified sender address.
            // extract sender address from the end of msg.data
            assembly {
                ret := shr(96,calldataload(sub(calldatasize(),20)))
            }
        } else {
            return super._msgSender();
        }
    }

    function _collect(
        uint256 _tokenId,
        IUniswapV3Pool _pool,
        int24 _tickLower,
        int24 _tickUpper,
        uint128 _tokensOwed0,
        uint256 _feeOwed0,
        uint128 _tokensOwed1,
        uint256 _feeOwed1,
        address _owner
    ) internal returns
        (uint256 _tokensToSend0, uint256 _tokensToSend1) {

        address _token0 = _pool.token0();
        address _token1 = _pool.token1();

        (_tokensToSend0, _tokensToSend1) =
            _pool.collect(
                 address(this),
                 _tickLower,
                _tickUpper,
                _tokensOwed0,
                _tokensOwed1
            );

        require(_tokensToSend0 > 0 || _tokensToSend1 > 0, "LOM_TS");

        uint256 _token0ProtocolFee = _feeOwed0
            .mul(protocolFee)
            .div(PROTOCOL_FEE_MULTIPLIER);

        uint256 _token1ProtocolFee = _feeOwed1
            .mul(protocolFee)
            .div(PROTOCOL_FEE_MULTIPLIER);

        _transferTokenTo(_token0, _tokensToSend0.sub(_token0ProtocolFee), _owner);
        _transferTokenTo(_token1, _tokensToSend1.sub(_token1ProtocolFee), _owner);

        _transferTokenTo(_token0, _token0ProtocolFee, feeAddress);
        _transferTokenTo(_token1, _token1ProtocolFee, feeAddress);

        emit LimitOrderCollected(_owner, _tokenId, _tokensToSend0, _tokensToSend1);
    }

    /// @dev Approve transfer to position manager
    function _approveAndTransferToUniswap(address _recipient, 
        address _token, uint256 _amount, address _owner) private {

        if (_amount > 0) {
            // transfer tokens to contract
            if (_token == address(WETH) && address(this).balance >= _amount) {
                // if _token is WETH --> wrap it first
                WETH.deposit{value: _amount}();
                require(WETH.transfer(_recipient, _amount), "LOM_WT");
            } else {
                TransferHelper.safeTransferFrom(_token, _owner, _recipient, _amount);
            }
        }
    }

    function _transferTokenTo(address _token, uint256 _amount, address _to) private {
        if (_amount > 0) {
            if (_token == address(WETH)) {
                // if token is WETH, withdraw and send back ETH
                WETH.withdraw(_amount);
                TransferHelper.safeTransferETH(_to, _amount);
            } else {
                TransferHelper.safeTransfer(_token, _to, _amount);
            }
        }
    }

    function tokensOfOwner(address _owner) external view returns(
        uint256[] memory ownerTokens
    ) {

        uint256 tokenCount = balanceOf(_owner);

        if (tokenCount == 0) {
            // Return an empty array
            return new uint256[](0);
        } else {
            uint256[] memory result = new uint256[](tokenCount);
            uint256 totalTokens = nextId - 1;
            uint256 resultIndex = 0;

            uint256 tokenId;

            for (tokenId = 1; tokenId <= totalTokens; tokenId++) {
                address tokenOwner = _owners[tokenId];
                if (tokenOwner != address(0) && tokenOwner == _owner) {
                    result[resultIndex] = tokenId;
                    resultIndex++;
                }
            }

            return result;
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
        uint256 feeOwed0,
        uint128 tokensOwed1,
        uint256 feeOwed1
    ) {

        if (_liquidity > 0) {
            (uint256 amount0, uint256 amount1) = _pool.burn(
                _tickLower, _tickUpper, _liquidity
            );

            bytes32 positionKey = PositionKey.compute(address(this), _tickLower, _tickUpper);
            (, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128, , ) = _pool.positions(positionKey);

            feeOwed0 = FullMath.mulDiv(
                feeGrowthInside0LastX128 - _feeGrowthInside0LastX128,
                _liquidity,
                FixedPoint128.Q128
            );
            tokensOwed0 = amount0.add(feeOwed0).toUint128();

            feeOwed1 = FullMath.mulDiv(
                feeGrowthInside1LastX128 - _feeGrowthInside1LastX128,
                _liquidity,
                FixedPoint128.Q128
            );
            tokensOwed1 = amount1.add(feeOwed1).toUint128();
        }
    }

    function isAuthorizedController() internal view {
        require(msg.sender == controller, "LOM_AC");
    }

    // Function to receive Ether. msg.data must be empty
    receive() external payable {}

    // Fallback function is called when msg.data is not empty
    fallback() external payable {}
}