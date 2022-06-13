// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.7.6;
pragma abicoder v2;

import "@openzeppelin/contracts/math/SafeMath.sol";

import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";

import "../interfaces/IOrderManager.sol";
import "../MulticallExtended.sol";
import "../SelfPermit.sol";

contract KromatikaForwarder is SelfPermit, MulticallExtended {

    using SafeMath for uint256;

    /// @dev route forwarded
    event RouteForwarded(address indexed target, address indexed owner, uint256 txnFeePaid);

    /// @dev controller
    address public controller;

    /// @dev trusted forwarder ; gasless relayer
    address public trustedForwarder;

    /// @dev payment token
    IERC20 public paymentToken;

    /// @dev fee receiver
    address public feeReceiver;

    uint256 public initialGas;

    uint256 public postCallGas;

    bool public subsidized;

    enum PaymentMethod
    {
        IN,
        OUT,
        SUBSIDIZED
    }

    constructor(
        address _trustedForwarder,
        address _feeReceiver
    ) {
        trustedForwarder = _trustedForwarder;
        feeReceiver = _feeReceiver;
        controller = msg.sender;
    }

    function executeCall(
        PaymentMethod paymentMethod,
        uint256 maxGasPrice,
        address targetAddress,
        bytes calldata data
    ) external returns (bool success, bytes memory result) {

        require(maxGasPrice >= tx.gasprice, 'KF_P');
        if (paymentMethod == PaymentMethod.SUBSIDIZED) {
            require(subsidized, "KF_S");
        }
        address sender = _msgSender();
        uint256 _gasUsed = gasleft().add(initialGas);

        // 1. prepaid
        uint256 tokenPrice = _tokenPrice(paymentToken);
        uint256 prepaidCharge = _calculateCharge(tokenPrice, _gasUsed, maxGasPrice);

        // if prepaid, transfer payment token right away from sender;
        if (paymentMethod == PaymentMethod.IN) {
            TransferHelper.safeTransferFrom(address(paymentToken), sender, address(this), prepaidCharge);
        }

        // 2. execute
        // solhint-disable-next-line avoid-call-value
        (success, result) = targetAddress.call(abi.encodePacked(data, sender));
        _gasUsed = _gasUsed.sub(gasleft()).sub(postCallGas);

        // 3. postpaid
        uint256 postPaidCharge = _calculateCharge(tokenPrice, _gasUsed, tx.gasprice);

        if (paymentMethod == PaymentMethod.OUT) {
            // if out; credit remaining amount
            require(postPaidCharge <= paymentToken.balanceOf(address(this)), "KF_FK");
            _transfer(paymentToken, feeReceiver, postPaidCharge);
            _transfer(paymentToken, sender, paymentToken.balanceOf(address(this)));
        }

        if (paymentMethod == PaymentMethod.IN) {
            // if in; credit the diff
            require(postPaidCharge <= paymentToken.balanceOf(address(this)), "KF_FK");
            _transfer(paymentToken, feeReceiver, postPaidCharge);
            _transfer(paymentToken, sender, prepaidCharge.sub(postPaidCharge));
        }

        emit RouteForwarded(targetAddress, sender, postPaidCharge);
    }

    function _tokenPrice(IERC20 _paymentToken) internal returns(uint256 price){

    }

    function _calculateCharge(uint256 tokenPrice,uint256 executionGas, uint256 gasPrice) internal returns(uint256 charge){
        charge = tokenPrice.mul(executionGas).mul(gasPrice);

        // TODO add margin
    }

    function _transfer(IERC20 tokenToTransfer, address recipient, uint256 amount) internal {
        // TODO check if amount <= adddress this balance
        if (amount > 0) {
            TransferHelper.safeTransfer(address(tokenToTransfer), recipient, amount);
        }
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