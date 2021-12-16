// SPDX-License-Identifier: MIT

pragma solidity >=0.7.5;
pragma abicoder v2;

import "@openzeppelin/contracts/math/SafeMath.sol";
import '@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol';
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "../Multicall.sol";

/// @title  OpAccessToken
contract OpAccessToken is ERC721Upgradeable, OwnableUpgradeable, Multicall {

    using Counters for Counters.Counter;
    Counters.Counter private _tokenIds;

    /// @notice Initializes the smart contract instead of a constructor
    function initialize() public initializer {
        OwnableUpgradeable.__Ownable_init();
        ERC721Upgradeable.__ERC721_init("Kromatika Optimism Access", "OP-KROM-NFT");
    }

    function mint(address _to) external onlyOwner {

        _tokenIds.increment();
        uint256 newTokenId = _tokenIds.current();
        _mint(_to, newTokenId);
    }
}