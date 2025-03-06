/**
 * SPDX-License-Identifier: MIT
 **/

pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IWell as IWellBase} from "src/interfaces/IWell.sol";

interface IWell is IWellBase {
    
    function addLiquidity(
        uint256[] memory tokenAmountsIn,
        uint256 minLpAmountOut,
        address recipient,
        uint256 deadline
    ) external returns (uint256 lpAmountOut);

    function getSwapIn(
        IERC20 fromToken,
        IERC20 toToken,
        uint256 amountOut
    ) external view returns (uint256 amountIn);

    function tokens() external view returns (IERC20[] memory);

    function shift(
        IERC20 tokenOut,
        uint256 minAmountOut,
        address recipient
    ) external returns (uint256 amountOut);

    function sync(address recipient, uint256 minLpAmountOut) external returns (uint256 lpAmountOut);
}
