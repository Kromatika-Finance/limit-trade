// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.7.6;
pragma abicoder v2;

/// @dev A transformation callback used in `TransformERC20.transformERC20()`.
interface IAdapter {

    /// @dev Context information to pass into `transform()` by `TransformERC20.transformERC20()`.
    struct AdapterContext {
        // The caller of `TransformERC20.transformERC20()`.
        address payable sender;
        // The recipient address, which may be distinct from `sender` e.g. in
        // meta-transactions.
        address payable recipient;
        // Arbitrary data to pass to the transformer.
        bytes data;
    }

    /// @dev Called from `TransformERC20.transformERC20()`. This will be
    ///      delegatecalled in the context of the FlashWallet instance being used.
    /// @param context Context information.
    /// @return success The success bytes (`LibERC20Transformer.TRANSFORMER_SUCCESS`).
    function adapt(AdapterContext calldata context)
    external
    payable
    returns (bytes4 success);
}