// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.7.6;

interface ITreasury {

    function incurDebt(address _owner, uint256 debt) external;

}