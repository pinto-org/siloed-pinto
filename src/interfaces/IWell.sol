// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title Call is the struct that contains the target address and extra calldata of a generic call.
 */
struct Call {
    address target; // The address the call is executed on.
    bytes data; // Extra calldata to be passed during the call
}

/**
 * @title IWell is the interface for the Well contract.
 *
 * In order for a Well to be verified using a permissionless on-chain registry, a Well Implementation should:
 * - Not be able to self-destruct (Aquifer's registry would be vulnerable to a metamorphic contract attack)
 * - Not be able to change its tokens, Well Function, Pumps and Well Data
 */
interface IWell {
    /**
     * @notice Returns the Pumps attached to the Well as Call structs.
     * @dev Contains the addresses of the Pumps contract and extra data to pass
     * during calls.
     *
     * **Pumps** are on-chain oracles that are updated every time the Well is
     * interacted with.
     *
     * A Pump is not required for Well operation. For Wells without a Pump:
     * `pumps().length = 0`.
     *
     * An attached Pump MUST implement {IPump}.
     */
    function pumps() external view returns (Call[] memory);

    /**
     * @notice Swaps from an exact amount of `fromToken` to a minimum amount of `toToken`.
     * @param fromToken The token to swap from
     * @param toToken The token to swap to
     * @param amountIn The amount of `fromToken` to spend
     * @param minAmountOut The minimum amount of `toToken` to receive
     * @param recipient The address to receive `toToken`
     * @param deadline The timestamp after which this operation is invalid
     * @return amountOut The amount of `toToken` received
     */
    function swapFrom(
        IERC20 fromToken,
        IERC20 toToken,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        uint256 deadline
    ) external returns (uint256 amountOut);

    //////////////////// SWAP: TO ////////////////////

    /**
     * @notice Swaps from a maximum amount of `fromToken` to an exact amount of `toToken`.
     * @param fromToken The token to swap from
     * @param toToken The token to swap to
     * @param maxAmountIn The maximum amount of `fromToken` to spend
     * @param amountOut The amount of `toToken` to receive
     * @param recipient The address to receive `toToken`
     * @param deadline The timestamp after which this operation is invalid
     * @return amountIn The amount of `toToken` received
     */
    function swapTo(
        IERC20 fromToken,
        IERC20 toToken,
        uint256 maxAmountIn,
        uint256 amountOut,
        address recipient,
        uint256 deadline
    ) external returns (uint256 amountIn);

    /**
     * @notice Gets the amount of one token received for swapping an amount of another token.
     * @param fromToken The token to swap from
     * @param toToken The token to swap to
     * @param amountIn The amount of `fromToken` to spend
     * @return amountOut The amount of `toToken` to receive
     */
    function getSwapOut(
        IERC20 fromToken,
        IERC20 toToken,
        uint256 amountIn
    ) external view returns (uint256 amountOut);

    /// @notice Returns the tokens in the well
    function tokens() external view returns (IERC20[] memory);

    // @notice Returns the name of the well
    function name() external view returns (string memory);

    /**
     * @notice Returns the Well function as a Call struct.
     * @dev Contains the address of the Well function contract and extra data to
     * pass during calls.
     *
     * **Well functions** define a relationship between the reserves of the
     * tokens in the Well and the number of LP tokens.
     *
     * A Well function MUST implement {IWellFunction}.
     */
    function wellFunction() external view returns (Call memory);

    /**
     * @notice Syncs the Well's reserves with the Well's balances of underlying tokens. If the reserves
     * increase, mints at least `minLpAmountOut` LP Tokens to `recipient`.
     * @param recipient The address to receive the LP tokens
     * @param minLpAmountOut The minimum amount of LP tokens to receive
     * @return lpAmountOut The amount of LP tokens received
     * @dev Can be used in a multicall using a contract like Pipeline to perform gas efficient additions of liquidity.
     * No deadline is needed since this function does not use the user's assets. If adding liquidity in a multicall,
     * then a deadline check can be added to the multicall.
     * If `sync` decreases the Well's reserves, then no LP tokens are minted and `lpAmountOut` must be 0.
     */
    function sync(address recipient, uint256 minLpAmountOut) external returns (uint256 lpAmountOut);
}
