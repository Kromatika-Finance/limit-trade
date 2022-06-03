// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.7.6;
pragma abicoder v2;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";

import "./interfaces/IAdapter.sol";

import "./FlashWallet.sol";

import "./LibERC20Adapter.sol";
import "./Constants.sol";

contract KromatikaMetaSwap is ReentrancyGuard, Pausable {

    using SafeMath for uint256;

    struct AdapterInfo{
        // adapterId
        string adapterId;
        // Arbitrary data to pass to the adapter.
        bytes data;
    }

    /// @dev controller
    address public controller;

    /// @dev trusted forwarder ; kromatika router
    address public trustedForwarder;

    /// @dev flash wallet
    IFlashWallet public flashWallet;

    /// @dev adapters
    mapping(string => address payable) public adapters;

    constructor() {
        controller = msg.sender;
    }

    function swap(
        IERC20 tokenFrom,
        uint256 amount,
        address payable recipient,
        AdapterInfo memory adapterInfo
    ) external payable whenNotPaused nonReentrant {

        require(address(flashWallet) != address(0), "MS_NULL");
        address payable adapter = adapters[adapterInfo.adapterId];
        require(adapter != address(0), "FW_NULL");

        address payable sender = _msgSender();
        if (recipient == Constants.MSG_SENDER) recipient = sender;

        if (!LibERC20Adapter.isTokenETH(tokenFrom)) {
            TransferHelper.safeTransferFrom(address(tokenFrom), sender, address(flashWallet), amount);
        } else {
            require(msg.value >= amount, 'msg.value');
        }

        // Call `adapter` as the wallet.
        bytes memory resultData = flashWallet.executeDelegateCall{ value: msg.value }(
        // The call adapter.
            adapter,
        // Call data.
            abi.encodeWithSelector(
                IAdapter.adapt.selector,
                IAdapter.AdapterContext({
                    sender: sender,
                    recipient: recipient,
                    data: adapterInfo.data
                })
            )
        );
        // Ensure the transformer returned the magic bytes.
        if (resultData.length != 32 ||
            abi.decode(resultData, (bytes4)) != LibERC20Adapter.TRANSFORMER_SUCCESS
        ) {
            revert(abi.decode(resultData, (string)));
        }
    }

    function changeAdapter(string calldata adapterId, address payable adapter) external {
        isAuthorizedController();
        require(adapter != address(0), "MS_NULL");
        adapters[adapterId] = adapter;
    }

    function createFlashWallet() public returns (IFlashWallet wallet) {
        isAuthorizedController();
        wallet = new FlashWallet();
        flashWallet = wallet;
    }

    function changeController(address _controller) external {
        isAuthorizedController();
        controller = _controller;
    }

    function changeForwarder(address _forwarder) external {
        isAuthorizedController();
        trustedForwarder = _forwarder;
    }

    function pause() external {
        isAuthorizedController();
        _pause();
    }

    function unpause() external {
        isAuthorizedController();
        _unpause();
    }

    function isAuthorizedController() internal view {
        require(msg.sender == controller, "KR_AC");
    }

    function isTrustedForwarder(address forwarder) internal view returns(bool) {
        return forwarder == trustedForwarder;
    }

    function _msgSender() internal virtual override view returns (address payable ret) {
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
}