/**
 * SPDX-License-Identifier: MIT
 **/

pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SiloedPinto} from "src/SiloedPinto.sol";
import "forge-std/console.sol";
import {IPintoProtocol, From, To} from "src/interfaces/IPintoProtocol.sol";

/**
 * @title SiloedPintoV2
 * @notice Wraps Silo deposits into an ERC20.
 * @dev Mock contract for testing upgrades.
 */

/// @custom:oz-upgrades-from SiloedPinto
contract SiloedPintoV2 is SiloedPinto {
    uint256 x;

    function initialize(uint256 _x) public reinitializer(2) {
        x = _x;
    }

    function version() external pure override returns (string memory) {
        return "2.0.0";
    }
}
