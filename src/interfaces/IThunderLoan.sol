// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// @audit-info the IThunderLoan contract should be implemented by the ThunderLoan contract
interface IThunderLoan {
    // @audit low/informational  (repay funtion in ThunderLoan.sol now takes IERC20 token instead of address token as an
    // argument)
    function repay(address token, uint256 amount) external;
}
