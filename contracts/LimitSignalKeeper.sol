pragma solidity >=0.7.5;
pragma abicoder v2;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "@chainlink/contracts/src/v0.7/interfaces/KeeperCompatibleInterface.sol";

import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";

import "./interfaces/ILimitSignalKeeper.sol";
import "./interfaces/ILimitTradeManager.sol";

/// @title  LimitSignalKeeper
contract LimitSignalKeeper is Ownable, ILimitSignalKeeper, KeeperCompatibleInterface {

    using SafeMath for uint256;

    struct Deposit {
        uint256 tokenId;
        uint256 tokensDeposit0;
        uint256 tokensDeposit1;
    }

    /// @dev deposits per token Id
    mapping (uint256 => Deposit) public depositPerTokenId;

    /// @dev tokenIds index per token id
    mapping (uint256 => uint256) public tokenIndexPerTokenId;

    /// @dev tokens to monitor
    uint256[] public tokenIds;

    /// @dev tokens to monitor
    uint256[] public filledTokenIds;

    /// @dev limit trade manager
    ILimitTradeManager public limitTradeManager;

    /// @dev uniV3 position manager
    INonfungiblePositionManager public immutable nonfungiblePositionManager;

    /// @dev univ3 factory
    IUniswapV3Factory factory;

    /// @dev only trade manager
    modifier onlyTradeManager() {
        require(msg.sender == address(limitTradeManager), "NOT_TRADE_MANAGER");
        _;
    }

    constructor(
        ILimitTradeManager _limitTradeManager,
        INonfungiblePositionManager _nonfungiblePositionManager,
        IUniswapV3Factory _factory) {

        limitTradeManager = _limitTradeManager;
        nonfungiblePositionManager = _nonfungiblePositionManager;
        factory = _factory;
    }


    function startMonitor(
        uint256 _tokenId, uint256 _amount0, uint256 _amount1
    ) external override onlyTradeManager {

        if (depositPerTokenId[_tokenId].tokenId == 0) {
            Deposit memory newDeposit = Deposit({
                tokenId: _tokenId,
                tokensDeposit0: _amount0,
                tokensDeposit1: _amount1
            });

            depositPerTokenId[_tokenId] = newDeposit;
            tokenIds.push(_tokenId);
            tokenIndexPerTokenId[_tokenId] = tokenIds.length;
        }
    }

    function stopMonitor(uint256 _tokenId) external onlyTradeManager {
        _stopMonitor(_tokenId);
    }

    function checkUpkeep(
        bytes calldata checkData
    )
    external override
    returns (
        bool upkeepNeeded,
        bytes memory performData
    ) {

        uint256 _tokenId;
        delete filledTokenIds;

        // iterate through all active tokens;
        for (uint256 i = 0; i < tokenIds.length; i++) {
            _tokenId = tokenIds[i];
            upkeepNeeded = _checkLimitConditions(_tokenId);
            if (upkeepNeeded) {
                filledTokenIds.push(_tokenId);
            }
        }

        upkeepNeeded = filledTokenIds.length > 0;
        if (upkeepNeeded) {
            performData = abi.encodePacked(filledTokenIds);
        }
    }

    function performUpkeep(
        bytes calldata performData
    ) external override {

        (uint256[] memory _tokenIds) = abi.decode(performData, (uint256[]));
        for (uint256 i = 0; i < _tokenIds.length; i++) {
            _stopMonitor(_tokenIds[i]);
            limitTradeManager.closeLimitTrade(_tokenIds[i]);
        }
    }

    function _stopMonitor(uint256 _tokenId) internal {

        // TODO checks

        delete depositPerTokenId[_tokenId];

        uint256 tokenIndexToRemove = tokenIndexPerTokenId[_tokenId];
        uint256 lastTokenId = tokenIds[tokenIds.length - 1];

        // move the last element into the deleted one
        // TODO handle edge cases
        tokenIds[tokenIndexToRemove] = lastTokenId;
        tokenIndexPerTokenId[lastTokenId] = tokenIndexToRemove;
    }

    function _checkLimitConditions(uint256 _tokenId) internal view
        returns (bool) {

        // get the position;
        (,,address _token0,address _token1,uint24 _fee,int24 tickLower,int24 tickUpper,uint128 liquidity,,,,) =
        nonfungiblePositionManager.positions(_tokenId);

        address _poolAddress = factory.getPool(_token0, _token1, _fee);
        (uint256 amount0, uint256 amount1) = _amountsForLiquidity(
            IUniswapV3Pool(_poolAddress), tickLower, tickUpper, liquidity
        );

        // compare the actual liquidity vs deposit liquidity
        Deposit storage deposit = depositPerTokenId[_tokenId];

        if (deposit.tokensDeposit0 > 0 && amount0 == 0) {
            return true;
        }

        if (deposit.tokensDeposit1 > 0 && amount1 == 0) {
            return true;
        }

        return false;
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

}