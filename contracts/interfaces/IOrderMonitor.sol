// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.7.6;

interface IOrderMonitor {

    function getTokenIdsLength() external view returns (uint256);

    function monitorSize() external view returns (uint256);

}