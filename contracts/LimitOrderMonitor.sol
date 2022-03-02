// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.7.6;
pragma abicoder v2;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts-upgradeable/proxy/Initializable.sol";

import "@chainlink/contracts/src/v0.7/interfaces/KeeperCompatibleInterface.sol";
import "@chainlink/contracts/src/v0.7/interfaces/AggregatorV3Interface.sol";
import "@chainlink/contracts/src/v0.7/KeeperBase.sol";

import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";

import "./interfaces/IOrderMonitor.sol";
import "./interfaces/IOrderManager.sol";

/// @title  LimitOrderMonitor
contract LimitOrderMonitor is
    Initializable,
    IOrderMonitor,
    KeeperCompatibleInterface,
    KeeperBase {

    using SafeMath for uint256;

    uint256 private constant MAX_INT = 2**256 - 1;
    uint256 private constant MAX_BATCH_SIZE = 100;
    uint256 private constant MAX_MONITOR_SIZE = 10000;

    event BatchProcessed(uint256 batchSize, uint256 gasUsed,
        uint256 paymentPaid, bytes data);

    /// @dev when batch size have changed
    event BatchSizeChanged(address from, uint256 newValue);

    /// @dev when monitor size have changed
    event MonitorSizeChanged(address from, uint256 newValue);

    /// @dev when upkeep interval changed
    event UpkeepIntervalChanged(address from, uint256 newValue);

    /// @dev when controller has changed
    event ControllerChanged(address from, address newValue);

    /// @dev when keeper has changed
    event KeeperChanged(address from, address newValue);

    /// @dev when monitor is started
    event MonitorStarted(uint256 tokenId);

    /// @dev when monitor is stopped
    event MonitorStopped(uint256 tokenId);

    /// @dev tokenIds index per token id
    mapping (uint256 => uint256) public tokenIndexPerTokenId;

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
    uint256 public override monitorSize;

    /// @dev interval between 2 upkeeps, in blocks
    uint256 public upkeepInterval;

    /// @dev monitor token offset
    uint256 public monitorOffset;

    constructor () initializer {}

    function initialize (IOrderManager _orderManager,
        IUniswapV3Factory _factory,
        IERC20 _KROM,
        address _keeper,
        uint256 _batchSize,
        uint256 _monitorSize,
        uint256 _upkeepInterval) public initializer {

        require(_batchSize <= MAX_BATCH_SIZE, "INVALID_BATCH_SIZE");
        require(_monitorSize <= MAX_MONITOR_SIZE, "INVALID_MONITOR_SIZE");
        require(_batchSize <= _monitorSize, "SIZE_MISMATCH");

        orderManager = _orderManager;
        factory = _factory;
        KROM = _KROM;

        batchSize = _batchSize;
        monitorSize = _monitorSize;
        upkeepInterval = _upkeepInterval;

        controller = msg.sender;
        keeper = _keeper;

        require(KROM.approve(address(orderManager), MAX_INT));
    }

    function checkUpkeep(
        bytes calldata
    )
    external override cannotExecute
    returns (
        bool upkeepNeeded,
        bytes memory performData
    ) {

        if (upkeepNeeded = (_getBlockNumber() - lastUpkeep) > upkeepInterval) {
            uint256[] memory batchTokenIds = new uint256[](batchSize);
            uint256 count;

            uint256 tokenSize = orderManager.getTokenIdsLength();
            uint256 tokenPagination = monitorOffset + monitorSize;
            tokenSize = tokenPagination > tokenSize ? tokenSize : tokenPagination;

            // iterate through all active tokens;
            for (uint256 i = monitorOffset; i < tokenSize; i++) {
                (upkeepNeeded,,) = orderManager.canProcess(
                    i,
                    _getGasPrice(tx.gasprice)
                );
                if (upkeepNeeded) {
                    batchTokenIds[count] = i;
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

        require((_getBlockNumber() - lastUpkeep) > upkeepInterval, "LOC_UL");

        uint256 _gasUsed = gasleft();

        (uint256[] memory _tokenIds, uint256 _count) = abi.decode(
            performData, (uint256[], uint256)
        );

        uint256 monitorFeePaid;
        uint256 validCount;

        {
            uint256 _tokenId;

            require(_count <= _tokenIds.length, "LOC_CL");
            require(_count <= batchSize, "LOC_BS");
            for (uint256 i = 0; i < _count; i++) {
                _tokenId = _tokenIds[i];

                (bool success, bytes memory data) = address(orderManager).call(
                    abi.encodeWithSignature("processLimitOrder(uint256)", _tokenId)
                );

                if (success) {
                    // parse the options;
                    (bool validTrade, uint256 _monitorFee) = abi.decode(
                        data, (bool, uint256)
                    );
                    if (validTrade) {
                        validCount++;
                        monitorFeePaid += _monitorFee;
                    }
                }
            }
        }

        // FIX when simulating with gasPrice=0; ignore the valid count
        require(tx.gasprice == 0 || validCount > 0, "LOC_VC");

        _gasUsed = _gasUsed - gasleft();
        lastUpkeep = _getBlockNumber();

        // send the paymentPaid to the keeper
        _transferFees(monitorFeePaid, keeper);

        emit BatchProcessed(
            validCount,
            _gasUsed,
            monitorFeePaid,
            performData
        );
    }

    function setMonitorOffset(uint256 _monitorOffset) external  {

        isAuthorizedController();
        monitorOffset = _monitorOffset;
    }

    function setBatchSize(uint256 _batchSize) external {

        isAuthorizedController();
        require(_batchSize <= MAX_BATCH_SIZE, "INVALID_BATCH_SIZE");
        require(_batchSize <= monitorSize, "SIZE_MISMATCH");

        batchSize = _batchSize;
        emit BatchSizeChanged(msg.sender, _batchSize);
    }

    function setMonitorSize(uint256 _monitorSize) external {

        isAuthorizedController();
        require(_monitorSize <= MAX_MONITOR_SIZE, "INVALID_MONITOR_SIZE");
        require(_monitorSize >= batchSize, "SIZE_MISMATCH");

        monitorSize = _monitorSize;
        emit MonitorSizeChanged(msg.sender, _monitorSize);
    }

    function setUpkeepInterval(uint256 _upkeepInterval) external  {

        isAuthorizedController();
        upkeepInterval = _upkeepInterval;
        emit UpkeepIntervalChanged(msg.sender, _upkeepInterval);
    }

    function changeController(address _controller) external {
        
        isAuthorizedController();
        controller = _controller;
        emit ControllerChanged(msg.sender, _controller);
    }

    function changeKeeper(address _keeper) external {

        isAuthorizedController();
        keeper = _keeper;
        emit KeeperChanged(msg.sender, _keeper);
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
        require(msg.sender == controller, "LOC_AC");
    }
}