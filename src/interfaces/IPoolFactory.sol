// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.20;

// explainer: This is probably the interface to work with poolfactory.sol from tSwap
// q: Why are we using TSwap?

interface IPoolFactory {
    function getPool(address tokenAddress) external view returns (address);
}
