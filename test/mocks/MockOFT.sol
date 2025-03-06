/**
 * SPDX-License-Identifier: MIT
 **/

pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockOFT
 */
contract MockOFT is ERC20 {
    constructor() ERC20("Mock Siloed Pinto OFT", "MsPINTO") {
        _mint(msg.sender, 1e18);
    }
}
