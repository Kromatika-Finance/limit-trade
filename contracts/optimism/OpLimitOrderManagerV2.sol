// SPDX-License-Identifier: MIT

pragma solidity >=0.7.5;
pragma abicoder v2;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import "../LimitOrderManagerV2.sol";

/// @title  OpLimitOrderManager
contract OpLimitOrderManagerV2 is LimitOrderManagerV2 {

    using SafeMath for uint256;

    /// @dev whitelisting enabled
    bool private whitelistingEnabled;

    /// @dev access token
    IERC721 OPAccessToken;

    /// @dev protocol fee discount for access token holders ; 0% discount --> 100% discount
    uint32 public protocolFeeDiscount;

    /// @notice Initializes the smart contract instead of a constructor
    /// @param  _factory univ3 factory
    /// @param  _quoter univ3 quoter
    /// @param  _WETH wrapped ETH
    /// @param  _utils limit manager utils
    /// @param  _KROM kromatika token
    /// @param  _feeAddress protocol fee address
    /// @param  _gasUsageMonitor estimated gas usage of monitors
    /// @param  _protocolFee charged fee
    /// @param  _protocolFeeDiscount discount applied on the protocol fee
    function initialize(
        IUniswapV3Factory _factory,
        IQuoter _quoter,
        IWETH9 _WETH,
        WETHExtended _WETHExtended,
        ManagerUtils _utils,
        IERC20 _KROM,
        IERC721 _OPAccessToken,
        address _feeAddress,
        uint256 _gasUsageMonitor,
        uint32  _protocolFee,
        uint32  _protocolFeeDiscount
    ) public initializer {

        whitelistingEnabled = true;
        OPAccessToken = _OPAccessToken;
        protocolFeeDiscount = _protocolFeeDiscount;

        super.initialize(
            _factory, _quoter, _WETH, _WETHExtended, _utils, _KROM,
            _feeAddress, _gasUsageMonitor, _protocolFee
        );
    }

    function placeLimitOrder(LimitOrderParams calldata params)
    public payable override returns (
        uint256 _tokenId
    ) {
        isAuthorizedUser();
        return super.placeLimitOrder(params);
    }

    function toggleWhitelisting(bool _whitelistingEnabled) external {

        isAuthorizedController();
        whitelistingEnabled = _whitelistingEnabled;
    }

    function estimateServiceFee(
        uint256 _targetGasPrice,
        uint256 _noOrders,
        address _owner) public override virtual
    returns (uint256 _serviceFee, uint256 _monitorFee) {

        (_serviceFee,_monitorFee) = super.estimateServiceFee(
            _targetGasPrice,
            _noOrders,
            _owner
        );

        // if _owner has the access NFT; give a discount on the protocol fee
        if (OPAccessToken.balanceOf(_owner) > 0) {
            uint256 _protocolFee = _serviceFee.sub(_monitorFee);

            _protocolFee = _protocolFee
                            .mul(PROTOCOL_FEE_MULTIPLIER.sub(protocolFeeDiscount))
                            .div(PROTOCOL_FEE_MULTIPLIER);

            _serviceFee = _monitorFee.add(_protocolFee);
        }
    }

    function isAuthorizedUser() internal view {
        require(whitelistingEnabled
            ? OPAccessToken.balanceOf(msg.sender) > 0
            : true, 'AD');
    }

}