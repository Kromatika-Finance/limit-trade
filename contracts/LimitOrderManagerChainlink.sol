// SPDX-License-Identifier: MIT

pragma solidity >=0.7.5;
pragma abicoder v2;

import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

import "@chainlink/contracts/src/v0.7/interfaces/KeeperRegistryInterface.sol";

import "./LimitOrderManager.sol";

/// @title  LimitOrderManagerChainlink
contract LimitOrderManagerChainlink is LimitOrderManager {

    /// @dev swap router
    ISwapRouter public swapRouter;

    /// @dev link token address
    IERC20 public LINK;

    /// @dev monitor to keeper id mapping
    mapping (address => uint256) public keeperIdPerMonitor;

    function initialize(INonfungiblePositionManager _nonfungiblePositionManager,
        IUniswapV3Factory _factory,
        IWETH9 _WETH,
        IERC20 _KROM,
        uint256 _monitorGasUsage,
        ISwapRouter _swapRouter,
        IERC20 _LINK) public initializer {

        super.initialize(_nonfungiblePositionManager, _factory, _WETH, _KROM, _monitorGasUsage);
        swapRouter = _swapRouter;
        LINK = _LINK;
    }

    function setKeeperIdPerMonitor(address _monitor, uint256 _keeperId) external onlyOwner {

        keeperIdPerMonitor[_monitor] = _keeperId;
    }

    function _transferFees(uint256 _amount, address _owner, address _monitor) override virtual internal {
        if (_amount > 0) {
            require(keeperIdPerMonitor[_monitor] > 0, "ERR_NO_KEEPER");
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
            KeeperRegistryInterface(_owner).addFunds(keeperIdPerMonitor[_monitor], uint96(_amount));
        }
    }
}