// SPDX-License-Identifier: MIT

pragma solidity >=0.7.5;
pragma abicoder v2;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "@chainlink/contracts/src/v0.7/interfaces/KeeperCompatibleInterface.sol";
import "@chainlink/contracts/src/v0.7/interfaces/AggregatorV3Interface.sol";

import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";

import "@uniswap/v3-periphery/contracts/interfaces/external/IWETH9.sol";
import "@uniswap/v3-periphery/contracts/interfaces/IQuoter.sol";

import "./interfaces/IOrderMonitor.sol";
import "./interfaces/IOrderManager.sol";

/// @title  LimitOrderMonitor
contract LimitOrderMonitor is OwnableUpgradeable, IOrderMonitor, KeeperCompatibleInterface {

    using SafeMath for uint256;

    struct Deposit {
        uint256 tokenId;
        uint256 tokensDeposit0;
        uint256 tokensDeposit1;
        uint256 targetGasPrice;
        address owner;
    }

    struct BatchInfo {
        uint256 payment;
        address creator;
    }

    uint256 private constant FEE_MULTIPLIER = 100000;
    uint256 private constant MAX_BATCH_SIZE = 100;
    uint256 private constant MAX_MONITOR_SIZE = 10000;

    uint256 private constant MONITOR_OVERHEAD = 100000;

    event BatchClosed(uint256 batchId, uint256 batchSize, uint256 gasUsed, uint256 payment, bytes data);

    /// @dev deposits per token Id
    mapping (uint256 => Deposit) public depositPerTokenId;

    /// @dev tokenIds index per token id
    mapping (uint256 => uint256) public tokenIndexPerTokenId;

    /// @dev tokens to monitor
    uint256[] public tokenIds;

    /// @dev order manager
    IOrderManager public orderManager;

    /// @dev uniV3 position manager
    INonfungiblePositionManager public nonfungiblePositionManager;

    /// @dev wrapper ETH
    IWETH9 public WETH;

    /// @dev univ3 factory
    IUniswapV3Factory public factory;

    /// @dev quoter V2
    IQuoter public quoter;

    /// @dev krom token
    IERC20 public KROM;

    /// @dev max batch size
    uint256 public batchSize;

    /// @dev max monitor size
    uint256 public monitorSize;

    /// @dev interval between 2 upkeeps, in blocks
    uint256 public upkeepInterval;

    /// @dev last upkeep block
    uint256 public lastUpkeep;

    /// @dev batch count
    uint256 public batchCount;

    //  @dev keeper fee monitorFee / FEE_MULTIPLIER = x
    uint256 public monitorFee;

    /// @dev batch info
    mapping(uint256 => BatchInfo) public override batchInfo;

    /// @dev only trade manager
    modifier onlyTradeManager() {
        require(msg.sender == address(orderManager), "NOT_TRADE_MANAGER");
        _;
    }

    function initialize (IOrderManager _orderManager,
        INonfungiblePositionManager _nonfungiblePositionManager,
        IUniswapV3Factory _factory,
        IWETH9 _WETH,
        IERC20 _KROM,
        IQuoter _quoter,
        uint256 _batchSize,
        uint256 _monitorSize,
        uint256 _upkeepInterval,
        uint256 _monitorFee) external initializer {

        require(_monitorFee <= FEE_MULTIPLIER, "INVALID_FEE");
        require(_batchSize <= MAX_BATCH_SIZE, "INVALID_BATCH_SIZE");
        require(_monitorSize <= MAX_MONITOR_SIZE, "INVALID_MONITOR_SIZE");
        require(_batchSize <= _monitorSize, "SIZE_MISMATCH");

        orderManager = _orderManager;
        nonfungiblePositionManager = _nonfungiblePositionManager;
        factory = _factory;
        WETH = _WETH;
        KROM = _KROM;
        quoter = _quoter;

        batchSize = _batchSize;
        monitorSize = _monitorSize;
        upkeepInterval = _upkeepInterval;
        monitorFee = _monitorFee;

        OwnableUpgradeable.__Ownable_init();
    }
    
    function startMonitor(
        uint256 _tokenId, uint256 _amount0, uint256 _amount1, uint256 _targetGasPrice, address _owner
    ) external override onlyTradeManager {

        require(tokenIds.length < monitorSize, "MONITOR_FULL");
        Deposit memory newDeposit = Deposit({
            tokenId: _tokenId,
            tokensDeposit0: _amount0,
            tokensDeposit1: _amount1,
            targetGasPrice: _targetGasPrice,
            owner: _owner
        });

        depositPerTokenId[_tokenId] = newDeposit;
        tokenIds.push(_tokenId);
        tokenIndexPerTokenId[_tokenId] = tokenIds.length;
    }

    function stopMonitor(uint256 _tokenId) external override onlyTradeManager {
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

        if (upkeepNeeded = (block.number - lastUpkeep) > upkeepInterval) {
            uint256 _tokenId;
            uint256[] memory batchTokenIds = new uint256[](batchSize);
            uint256 count;

            // iterate through all active tokens;
            for (uint256 i = 0; i < tokenIds.length; i++) {
                _tokenId = tokenIds[i];
                upkeepNeeded = _checkLimitConditions(_tokenId);
                if (upkeepNeeded) {
                    batchTokenIds[count] = _tokenId;
                    count++;
                }
                if (count >= batchSize) {
                    break;
                }
            }

            upkeepNeeded = count > 0;
            if (upkeepNeeded) {
                performData = abi.encode(batchTokenIds, count);
            }
        }
    }

    function performUpkeep(
        bytes calldata performData
    ) external override {

        uint256 _gasUsed = gasleft();
        batchCount++;

        (uint256[] memory _tokenIds, uint256 _count) = abi.decode(
            performData, (uint256[], uint256)
        );

        uint256 _tokenId;
        for (uint256 i = 0; i < _count; i++) {
            _tokenId = _tokenIds[i];
            require(_checkLimitConditions(_tokenId), "INVALID_TRADE");
            _stopMonitor(_tokenId);
            orderManager.closeOrder(_tokenId, batchCount);
        }

        _gasUsed = _gasUsed - gasleft();

        // convert to KROM
        uint256 payment = _calculatePaymentAmount(_gasUsed);

        // TODO (pai) how we can send the funds to sender right away
        // without looping through all tokens once again

        batchInfo[batchCount] = BatchInfo({
            payment: payment.div(_count),
            creator: msg.sender
        });
        lastUpkeep = block.number;

        emit BatchClosed(batchCount, _count, _gasUsed, payment, performData);
    }

    function setBatchSize(uint256 _batchSize) external onlyOwner {

        require(_batchSize <= MAX_BATCH_SIZE, "INVALID_BATCH_SIZE");
        require(_batchSize <= monitorSize, "SIZE_MISMATCH");

        batchSize = _batchSize;
    }

    function setMonitorSize(uint256 _monitorSize) external onlyOwner {

        require(_monitorSize <= MAX_MONITOR_SIZE, "INVALID_MONITOR_SIZE");
        require(_monitorSize >= batchSize, "SIZE_MISMATCH");

        monitorSize = _monitorSize;
    }

    function setUpkeepInterval(uint256 _upkeepInterval) external onlyOwner {

        upkeepInterval = _upkeepInterval;
    }

    function setKeeperFee(uint256 _keeperFee) external onlyOwner {

        require(_keeperFee <= FEE_MULTIPLIER, "INVALID_FEE");
        monitorFee = _keeperFee;
    }

    function _quoteKROM(uint256 _amount) private returns (uint256 quote) {

        address _poolAddress = factory.getPool(address(WETH), address(KROM), 3000);
        if (_poolAddress == address(0)) {
            return 0;
        }
        quote = quoter.quoteExactInputSingle(
            address(WETH), address(KROM), 3000, _amount, 0
        );
    }

    function _stopMonitor(uint256 _tokenId) internal {

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

    function _checkLimitConditions(uint256 _tokenId) internal
        returns (bool) {

        Deposit storage deposit = depositPerTokenId[_tokenId];

        (bool underfunded,) = orderManager.isUnderfunded(deposit.owner);

        // if current gas price is higher and underfunded --> quit
        if (underfunded && tx.gasprice > deposit.targetGasPrice) {
            return false;
        }

        // get the position;
        (,,address _token0,address _token1,uint24 _fee,int24 tickLower,int24 tickUpper,uint128 liquidity,,,,) =
        nonfungiblePositionManager.positions(_tokenId);

        address _poolAddress = factory.getPool(_token0, _token1, _fee);
        (uint256 amount0, uint256 amount1) = _amountsForLiquidity(
            IUniswapV3Pool(_poolAddress), tickLower, tickUpper, liquidity
        );

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

    function _calculatePaymentAmount(uint256 _gasUsed) internal
    returns (uint256 payment) {

        uint256 gasWei = tx.gasprice;
        uint256 _weiForGas = gasWei.mul(_gasUsed.add(MONITOR_OVERHEAD));
        _weiForGas = _weiForGas.mul(FEE_MULTIPLIER.add(monitorFee)).div(FEE_MULTIPLIER);

        payment = _quoteKROM(_weiForGas);
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

    // Function to receive Ether. msg.data must be empty
    receive() external payable {}

    // Fallback function is called when msg.data is not empty
    fallback() external payable {}

}