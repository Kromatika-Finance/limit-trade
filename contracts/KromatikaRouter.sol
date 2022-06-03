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

    /// @dev whitelisted addresses
    mapping(address => bool) public whitelisted;

    constructor(
        address _trustedForwarder
    ) {
        trustedForwarder = _trustedForwarder;
        controller = msg.sender;
    }

    function executeCall(
        address targetAddress,
        bytes calldata data
    ) external payable returns (bool success, bytes memory result) {

        require(whitelisted[targetAddress], "KR_WL"); // metaswap or limit orderManager
        address sender = _msgSender();

        uint256 _gasUsed = gasleft();
        // solhint-disable-next-line avoid-call-value
        (success, result) = targetAddress.call(abi.encodePacked(data, sender));

        _gasUsed = _gasUsed - gasleft();
        emit RouteForwarded(targetAddress, sender, _gasUsed.mul(tx.gasprice));
    }

    function isTrustedForwarder(address forwarder) internal view returns(bool) {
        return forwarder == trustedForwarder;
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

    function changeWhitelisted(address whitelistedAddress, bool toggle) external {
        isAuthorizedController();
        whitelisted[whitelistedAddress] = toggle;
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