// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.7.6;
pragma abicoder v2;

import "@openzeppelin/contracts/math/SafeMath.sol";

import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";

import "./interfaces/IOrderManager.sol";


contract KromatikaRouter {

    using SafeMath for uint256;

    /// @dev route forwarded
    event RouteForwarded(address indexed target, address indexed owner, uint256 txnFeePaid);

    /// @dev controller
    address public controller;

    /// @dev trusted forwarder ; gasless relayer
    address public trustedForwarder;

    /// @dev order manager
    IOrderManager public orderManager;

    /// @dev keeper address; sending funds to
    address public keeper;

    /// @dev base gas
    uint256 public baseGas;

    address public KROM;

    /// @dev whitelisted
    mapping(address => bool) public whitelisted;

    constructor(
        address _trustedForwarder,
        address _keeper,
        address _KROM,
        IOrderManager _orderManager,
        uint256 _baseGas
    ) {
        trustedForwarder = _trustedForwarder;
        controller = msg.sender;

        orderManager = _orderManager;
        KROM = _KROM;

        keeper = _keeper;
        baseGas = _baseGas;
    }

    function executeCall(
        address targetAddress,
        bytes calldata data
    ) external payable returns (bool success, bytes memory result) {

        require(isTrustedForwarder(msg.sender), "KR_TF");
        require(whitelisted[targetAddress], "KR_WL"); // metaswap or limit orderManager

        address _owner = _msgSender();

        uint256 _gasUsed = gasleft();
        // solhint-disable-next-line avoid-call-value
        if (targetAddress == address(this)) {
            (success, result) = address(this).call(abi.encodePacked(data, _owner));
        } else {
            (success, result) = targetAddress.call(abi.encodePacked(data, _owner));
        }

        _gasUsed = _gasUsed - gasleft();
        uint256 weiAmount = _calculateTxnCost(_gasUsed, tx.gasprice);

        // calculate KROM
        uint256 kromAmount = orderManager.quoteKROM(weiAmount);

        // TODO apply fee multiplier

        // transfer KROM
        TransferHelper.safeTransferFrom(KROM, _owner, keeper, kromAmount);

        emit RouteForwarded(targetAddress, _owner, weiAmount);
    }

    function isTrustedForwarder(address forwarder) internal view returns(bool) {
        return forwarder == trustedForwarder;
    }

    function _calculateTxnCost(uint256 _gasUsed, uint256 _gasPrice) internal view returns (uint256) {
        return _gasUsed.add(baseGas).mul(_gasPrice);
    }

    function _msgSender() internal virtual view returns (address payable ret) {
        if (msg.data.length >= 24 && isTrustedForwarder(msg.sender)) {
            // At this point we know that the sender is a trusted forwarder,
            // so we trust that the last bytes of msg.data are the verified sender address.
            // extract sender address from the end of msg.data
            assembly {
                ret := shr(96,calldataload(sub(calldatasize(),20)))
            }
        } else {
            return msg.sender;
        }
    }

    function changeForwarder(address _forwarder) external {
        isAuthorizedController();
        trustedForwarder = _forwarder;
    }

    function changeKeeper(address _keeper) external {
        isAuthorizedController();
        keeper = _keeper;
    }

    function changeController(address _controller) external {
        isAuthorizedController();
        controller = _controller;
    }

    function versionRecipient() external pure returns (string memory) {
        return "1";
    }

    function isAuthorizedController() internal view {
        require(msg.sender == controller, "KR_AC");
    }
}