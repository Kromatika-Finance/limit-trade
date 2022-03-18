// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.7.6;
pragma abicoder v2;

import "@openzeppelin/contracts/math/SafeMath.sol";
import '@openzeppelin/contracts/drafts/IERC20Permit.sol';

import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";

import "./interfaces/IUniswapUtils.sol";
import "./interfaces/ITreasury.sol";

contract KromatikaRouter {

    using SafeMath for uint256;

    /// @dev route forwarded
    event RouteForwarded(address indexed target, address indexed owner, uint256 txnFeePaid);

    /// @dev controller
    address public controller;

    /// @dev address to borrow fees from
    address public treasuryAddress;

    /// @dev trusted forwarder
    address public trustedForwarder;

    /// @dev base gas
    uint256 public baseGas;

    /// @dev whitelisted
    mapping(address => bool) public whitelisted;

    constructor(
        address _trustedForwarder,
        address _treasury,
        uint256 _baseGas
    ) {
        trustedForwarder = _trustedForwarder;
        controller = msg.sender;

        treasuryAddress = _treasury;
        baseGas = _baseGas;
    }

    function execute(
        address targetAddress,
        bytes calldata data
    ) external payable returns (bool success, bytes memory result) {

        require(msg.sender == trustedForwarder);
        require(whitelisted[targetAddress], "KR_WL");

        address _owner = _msgSender();
        uint256 _gasUsed = gasleft();
        // solhint-disable-next-line avoid-call-value
        (success, result) = targetAddress.call(abi.encodePacked(data, _owner));

        _gasUsed = _gasUsed - gasleft();
        uint256 weiAmount = _gasUsed.add(baseGas).mul(tx.gasprice);

        if (weiAmount > 0) {
            ITreasury(treasuryAddress).incurDebt(_owner, weiAmount);
        }

        emit RouteForwarded(targetAddress, _owner, weiAmount);
    }

    function isTrustedForwarder(address forwarder) public view returns(bool) {
        return forwarder == trustedForwarder;
    }

    function _msgSender() internal virtual view returns (address ret) {
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

    function changeTreasury(address _treasury) external {
        isAuthorizedController();
        treasuryAddress = _treasury;
    }

    function changeController(address _controller) external {
        isAuthorizedController();
        controller = _controller;
    }

    function versionRecipient() external pure returns (string memory) {
        return "1";
    }

    function isAuthorizedController() internal view {
        require(msg.sender == controller, "LOM_AC");
    }
}