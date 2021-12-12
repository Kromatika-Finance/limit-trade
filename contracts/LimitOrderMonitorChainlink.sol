// SPDX-License-Identifier: MIT

pragma solidity >=0.7.5;
pragma abicoder v2;

import "@chainlink/contracts/src/v0.7/interfaces/KeeperRegistryInterface.sol";

import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v3-periphery/contracts/interfaces/external/IWETH9.sol";

import "./LimitOrderMonitor.sol";

/// @title  LimitOrderMonitorChainlink
contract LimitOrderMonitorChainlink is LimitOrderMonitor {

    uint24 public constant POOL_FEE = 3000;

    /// @dev swap router
    ISwapRouter public swapRouter;

    /// @dev wrapper ETH
    IWETH9 public WETH;

    /// @dev link token address
    IERC20 public LINK;

    /// @dev monitor keeperID
    uint256 public keeperId;

    function initialize(IOrderManager _orderManager,
        IUniswapV3Factory _factory,
        IERC20 _KROM,
        uint24 _batchSize,
        uint24 _monitorSize,
        uint24 _upkeepInterval,
        uint24 _monitorFee,
        ISwapRouter _swapRouter,
        IWETH9 _WETH,
        IERC20 _LINK) public initializer {

        super.initialize(
            _orderManager, _factory, _KROM, _batchSize, _monitorSize, _upkeepInterval, _monitorFee
        );

        swapRouter = _swapRouter;
        LINK = _LINK;
        WETH = _WETH;
    }

    function setKeeperId(uint256 _keeperId) external {

        isAuthorizedController();
        keeperId = _keeperId;
    }

    function _transferFees(uint256 _amount, address _owner) internal virtual override  {

        if (_amount > 0) {
            require(keeperId > 0);
            // swap KROM into LINKs
            TransferHelper.safeApprove(address(KROM), address(swapRouter), _amount);

            ISwapRouter.ExactInputParams memory params =
            ISwapRouter.ExactInputParams({
                path: abi.encodePacked(address(KROM), POOL_FEE, address(WETH), POOL_FEE, address(LINK)),
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: _amount,
                amountOutMinimum: 0
            });

            // swap and send
            _amount = swapRouter.exactInput(params);

            TransferHelper.safeApprove(address(LINK), _owner, _amount);
            KeeperRegistryInterface(_owner).addFunds(keeperId, uint96(_amount));
        }
    }
}