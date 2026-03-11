// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @dev Mock factory that returns true for any registered pool
contract MockRiskPoolFactory {
    mapping(address => bool) public validPools;

    function registerPool(address pool) external {
        validPools[pool] = true;
    }

    function isValidPool(address poolAddress) external view returns (bool) {
        return validPools[poolAddress];
    }
}
