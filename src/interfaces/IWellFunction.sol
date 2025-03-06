// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

/**
 * @title IWellFunction
 * @notice Defines a relationship between token reserves and LP token supply.
 * @dev Well Functions can contain arbitrary logic, but should be deterministic
 * if expected to be used alongside a Pump. When interacing with a Well or
 * Well Function, always verify that the Well Function is valid.
 */
interface IWellFunction {
    /**
     * @notice Calculates the `j`th reserve given a list of `reserves` and `lpTokenSupply`.
     * @param reserves A list of token reserves. The jth reserve will be ignored, but a placeholder must be provided.
     * @param j The index of the reserve to solve for
     * @param lpTokenSupply The supply of LP tokens
     * @param data Extra Well function data provided on every call
     * @return reserve The resulting reserve at the jth index
     * @dev Should round up to ensure that Well reserves are marginally higher to enforce calcLpTokenSupply(...) >= totalSupply()
     */
    function calcReserve(
        uint256[] memory reserves,
        uint256 j,
        uint256 lpTokenSupply,
        bytes calldata data
    ) external view returns (uint256 reserve);

    /**
     * @notice Gets the LP token supply given a list of reserves.
     * @param reserves A list of token reserves
     * @param data Extra Well function data provided on every call
     * @return lpTokenSupply The resulting supply of LP tokens
     * @dev Should round down to ensure so that the Well Token supply is marignally lower to enforce calcLpTokenSupply(...) >= totalSupply()
     */
    function calcLpTokenSupply(
        uint[] memory reserves,
        bytes calldata data
    ) external view returns (uint lpTokenSupply);
}
