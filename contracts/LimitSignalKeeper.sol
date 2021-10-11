pragma solidity >=0.7.5;
pragma abicoder v2;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "@chainlink/contracts/src/v0.7/interfaces/KeeperCompatibleInterface.sol";
import "@chainlink/contracts/src/v0.7/interfaces/AggregatorV3Interface.sol";

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

    struct BatchInfo {
        uint256 count;
        uint256 gasCost;
    }

    uint256 private constant GAS_OVERHEAD = 100_000;

    event BatchClosed(uint256 batchId, uint256 batchSize, uint256 gasUsed);

    /// @dev deposits per token Id
    mapping (uint256 => Deposit) public depositPerTokenId;

    /// @dev tokenIds index per token id
    mapping (uint256 => uint256) public tokenIndexPerTokenId;

    /// @dev tokens to monitor
    uint256[] public tokenIds;

    /// @dev limit trade manager
    ILimitTradeManager public limitTradeManager;

    /// @dev uniV3 position manager
    INonfungiblePositionManager public immutable nonfungiblePositionManager;

    /// @dev univ3 factory
    IUniswapV3Factory factory;

    /// @dev max batch size
    uint256 public maxBatchSize;

    uint256 batchCount;

    mapping(uint256 => BatchInfo) public override batchInfo;

    AggregatorV3Interface public immutable FAST_GAS_FEED;

    /// @dev only trade manager
    modifier onlyTradeManager() {
        require(msg.sender == address(limitTradeManager), "NOT_TRADE_MANAGER");
        _;
    }

    constructor(ILimitTradeManager _limitTradeManager,
        INonfungiblePositionManager _nonfungiblePositionManager,
        IUniswapV3Factory _factory,
        AggregatorV3Interface _fastGasFeed) {

        limitTradeManager = _limitTradeManager;
        nonfungiblePositionManager = _nonfungiblePositionManager;
        factory = _factory;

        FAST_GAS_FEED = _fastGasFeed;

        maxBatchSize = 100;
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
        uint256[] memory batchTokenIds = new uint256[](maxBatchSize);
        uint256 count;

        // iterate through all active tokens;
        for (uint256 i = 0; i < tokenIds.length; i++) {
            _tokenId = tokenIds[i];
            upkeepNeeded = _checkLimitConditions(_tokenId);
            if (upkeepNeeded) {
                batchTokenIds[count] = _tokenId;
                count++;
            }
            if (count >= maxBatchSize) {
                break;
            }
        }

        upkeepNeeded = count > 0;
        if (upkeepNeeded) {
            performData = abi.encode(batchTokenIds, count);
        }
    }

    function performUpkeep(
        bytes calldata performData
    ) external override {

        uint256 gasUsed = gasleft();
        batchCount++;

        (uint256[] memory _tokenIds, uint256 count) = abi.decode(
            performData, (uint256[], uint256)
        );
        for (uint256 i = 0; i < count; i++) {
            _stopMonitor(_tokenIds[i]);
            limitTradeManager.closeLimitTrade(_tokenIds[i], batchCount);
        }

        gasUsed = gasUsed - gasleft();
        // TODO multiply the gasUsed with a ceiling multiplier

        // 1. multiply gasUsed with fast gas price to get the eth used
        (,int256 feedValue, ,uint256 timestamp, ) = FAST_GAS_FEED.latestRoundData();
        uint256 weiForGas = uint256(feedValue).mul(gasUsed.add(GAS_OVERHEAD));

        // 2. save batch Info (count, total gascost, price)
        batchInfo[batchCount] = BatchInfo({
            count: count,
            gasCost: weiForGas
        });

        emit BatchClosed(batchCount, count, gasUsed);
    }

    function _stopMonitor(uint256 _tokenId) internal {

        // TODO checks

        delete depositPerTokenId[_tokenId];

        uint256 tokenIndexToRemove = tokenIndexPerTokenId[_tokenId] - 1;
        uint256 lastTokenId = tokenIds[tokenIds.length - 1];

        removeElementFromArray(tokenIndexToRemove, tokenIds);

        if (tokenIds.length == 0) {
            delete tokenIndexPerTokenId[lastTokenId];
        } else if (tokenIndexToRemove != tokenIds.length) {
            tokenIndexPerTokenId[lastTokenId] = tokenIndexToRemove + 1;
        }
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

        if (deposit.tokensDeposit0 == 0 && amount0 > 0
            && deposit.tokensDeposit1 > 0 && amount1 == 0) {
            return true;
        }

        if (deposit.tokensDeposit0 > 0 && amount0 == 0
            && deposit.tokensDeposit1 == 0 && amount1 > 0) {
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

    /// @notice Removes index element from the given array.
    /// @param  index index to remove from the array
    /// @param  array the array itself
    function removeElementFromArray(uint256 index, uint256[] storage array) private {
        if (index == array.length - 1) {
            array.pop();
        } else {
            array[index] = array[array.length - 1];
            array.pop();
        }
    }

}