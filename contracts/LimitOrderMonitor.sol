// SPDX-License-Identifier: MIT

pragma solidity >=0.7.5;
pragma abicoder v2;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts-upgradeable/proxy/Initializable.sol";

import "@chainlink/contracts/src/v0.7/interfaces/KeeperCompatibleInterface.sol";
import "@chainlink/contracts/src/v0.7/interfaces/AggregatorV3Interface.sol";

import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";

import "./interfaces/IOrderMonitor.sol";
import "./interfaces/IOrderManager.sol";

/// @title  LimitOrderMonitor
contract LimitOrderMonitor is
    Initializable,
    IOrderMonitor,
    KeeperCompatibleInterface {

    using SafeMath for uint256;

    uint256 private constant MAX_INT = 2**256 - 1;
    uint256 private constant FEE_MULTIPLIER = 100000;
    uint256 private constant MAX_BATCH_SIZE = 100;
    uint256 private constant MAX_MONITOR_SIZE = 10000;

    uint256 private constant MONITOR_OVERHEAD = 300000;

    event BatchProcessed(uint256 batchId, uint256 batchSize, uint256 gasUsed,
        uint256 paymentOwed, uint256 paymentPaid, bytes data);

    /// @dev tokenIds index per token id
    mapping (uint256 => uint256) public tokenIndexPerTokenId;

    /// @dev batch info
    mapping(uint256 => uint256) public override batchPayment;

    /// @dev tokens to monitor
    uint256[] public tokenIds;

    /// @dev controller address; could be DAO
    address public controller;

    /// @dev keeper address; can do upkeep
    address public keeper;

    /// @dev order manager
    IOrderManager public orderManager;

    /// @dev univ3 factory
    IUniswapV3Factory public factory;

    /// @dev krom token
    IERC20 public KROM;

    /// @dev last upkeep block
    uint256 public lastUpkeep;

    /// @dev max batch size
    uint256 public batchSize;

    /// @dev max monitor size
    uint256 public monitorSize;

    /// @dev interval between 2 upkeeps, in blocks
    uint256 public upkeepInterval;

    /// @dev batch count
    uint256 public batchCount;

    //  @dev keeper fee monitorFee / FEE_MULTIPLIER = x
    uint256 public monitorFee;

    /// @dev only trade manager
    modifier onlyTradeManager() {
        require(msg.sender == address(orderManager), "NOT_TRADE_MANAGER");
        _;
    }

    function initialize (IOrderManager _orderManager,
        IUniswapV3Factory _factory,
        IERC20 _KROM,
        address _keeper,
        uint256 _batchSize,
        uint256 _monitorSize,
        uint256 _upkeepInterval,
        uint256 _monitorFee) public initializer {

        require(_monitorFee <= FEE_MULTIPLIER, "INVALID_FEE");
        require(_batchSize <= MAX_BATCH_SIZE, "INVALID_BATCH_SIZE");
        require(_monitorSize <= MAX_MONITOR_SIZE, "INVALID_MONITOR_SIZE");
        require(_batchSize <= _monitorSize, "SIZE_MISMATCH");

        orderManager = _orderManager;
        factory = _factory;
        KROM = _KROM;

        batchSize = _batchSize;
        monitorSize = _monitorSize;
        upkeepInterval = _upkeepInterval;
        monitorFee = _monitorFee;

        controller = msg.sender;
        keeper = _keeper;

        KROM.approve(address(orderManager), MAX_INT);
    }
    
    function startMonitor(uint256 _tokenId) external override onlyTradeManager {

        require(tokenIds.length < monitorSize, "MONITOR_FULL");
        tokenIds.push(_tokenId);
        tokenIndexPerTokenId[_tokenId] = tokenIds.length;
    }

    function stopMonitor(uint256 _tokenId) external override onlyTradeManager {
        _stopMonitor(_tokenId);
    }

    function checkUpkeep(
        bytes calldata
    )
    external view override
    returns (
        bool upkeepNeeded,
        bytes memory performData
    ) {

        if (upkeepNeeded = (_getBlockNumber() - lastUpkeep) > upkeepInterval) {
            uint256 _tokenId;
            uint256[] memory batchTokenIds = new uint256[](batchSize);
            uint256 count;

            // iterate through all active tokens;
            for (uint256 i = 0; i < tokenIds.length; i++) {
                _tokenId = tokenIds[i];
                (upkeepNeeded,,) = orderManager.canProcess(
                    _tokenId,
                    _getGasPrice(tx.gasprice)
                );
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

        isAuthorizedKeeper();
        uint256 _gasUsed = gasleft();

        batchCount++;

        (uint256[] memory _tokenIds, uint256 _count) = abi.decode(
            performData, (uint256[], uint256)
        );

        uint256 paymentPaid;
        uint256 validCount;

        {
            bool validTrade;
            uint256 _serviceFee;
            uint256 _monitorFee;
            uint256 _tokenId;
            for (uint256 i = 0; i < _count; i++) {
                _tokenId = _tokenIds[i];
                (validTrade, _serviceFee, _monitorFee) = orderManager.canProcess(_tokenId, tx.gasprice);
                if (validTrade) {
                    validCount++;
                    _stopMonitor(_tokenId);
                    orderManager.processLimitOrder(
                        _tokenId, batchCount, _serviceFee, _monitorFee
                    );
                    paymentPaid = paymentPaid.add(_monitorFee);
                }
            }
        }

        require(validCount > 0);

        _gasUsed = _gasUsed - gasleft();

        // calculate the payment owed to the sender
        uint256 paymentOwed = _calculatePaymentAmount(_gasUsed, validCount);
        require(paymentPaid >= paymentOwed);

        batchPayment[batchCount] = paymentOwed.div(validCount);
        lastUpkeep = block.number;

        // send the paymentOwed to the sender
        _transferFees(paymentOwed, msg.sender);

        emit BatchProcessed(
            batchCount,
            validCount,
            _gasUsed,
            paymentOwed,
            paymentPaid,
            performData
        );
    }

    function setBatchSize(uint256 _batchSize) external {

        isAuthorizedController();
        require(_batchSize <= MAX_BATCH_SIZE, "INVALID_BATCH_SIZE");
        require(_batchSize <= monitorSize, "SIZE_MISMATCH");

        batchSize = _batchSize;
    }

    function setMonitorSize(uint256 _monitorSize) external {

        isAuthorizedController();
        require(_monitorSize <= MAX_MONITOR_SIZE, "INVALID_MONITOR_SIZE");
        require(_monitorSize >= batchSize, "SIZE_MISMATCH");

        monitorSize = _monitorSize;
    }

    function setUpkeepInterval(uint256 _upkeepInterval) external  {

        isAuthorizedController();
        upkeepInterval = _upkeepInterval;
    }

    function setKeeperFee(uint256 _keeperFee) external {

        isAuthorizedController();
        require(_keeperFee <= FEE_MULTIPLIER, "INVALID_FEE");
        monitorFee = _keeperFee;
    }

    function changeController(address _controller) external {
        isAuthorizedController();
        controller = _controller;
    }

    function changeKeeper(address _keeper) external {
        isAuthorizedController();
        keeper = _keeper;
    }

    function _stopMonitor(uint256 _tokenId) internal {

        uint256 tokenIndexToRemove = tokenIndexPerTokenId[_tokenId] - 1;
        uint256 lastTokenId = tokenIds[tokenIds.length - 1];

        removeElementFromArray(tokenIndexToRemove, tokenIds);

        if (tokenIds.length == 0) {
            delete tokenIndexPerTokenId[lastTokenId];
        } else if (tokenIndexToRemove != tokenIds.length) {
            tokenIndexPerTokenId[lastTokenId] = tokenIndexToRemove + 1;
            delete tokenIndexPerTokenId[_tokenId];
        }
    }

    // TODO override for ARB only uint256 paymentOwed = _calculatePaymentAmount(orderManager.gasUsageMonitor().mul(validCount));
    function _calculatePaymentAmount(uint256 _gasUsed, uint256) internal virtual view
    returns (uint256 payment) {

        uint256 gasWei = tx.gasprice;
        uint256 _weiForGas = gasWei.mul(_gasUsed.add(MONITOR_OVERHEAD));
        _weiForGas = _weiForGas.mul(FEE_MULTIPLIER.add(monitorFee)).div(FEE_MULTIPLIER);

        payment = orderManager.quoteKROM(_weiForGas);
    }

    // TODO override for chainlink (use fast gas)
    function _getGasPrice(uint256 _txnGasPrice) internal virtual view
    returns (uint256 gasPrice) {
        gasPrice = _txnGasPrice > 0 ? _txnGasPrice : 0;
    }

    // TODO (override block numbers for L2)
    function _getBlockNumber() internal virtual view
    returns (uint256 blockNumber) {
        blockNumber = block.number;
    }

    function _transferFees(uint256 _amount, address _owner) internal virtual {
        if (_amount > 0) {
            TransferHelper.safeTransfer(address(KROM), _owner, _amount);
        }
    }

    function isAuthorizedController() internal view {
        require(msg.sender == controller);
    }

    function isAuthorizedKeeper() internal view {
        require(msg.sender == keeper);
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