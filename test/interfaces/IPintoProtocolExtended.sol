/**
 * SPDX-License-Identifier: MIT
 **/

pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPintoProtocol as IPintoProtocolBase} from "src/interfaces/IPintoProtocol.sol";
import {From, To, Implementation, Season, TokenDepositId, Deposit} from "src/interfaces/IPintoProtocol.sol";

interface IPintoProtocolExtended is IPintoProtocolBase {
    function totalDeltaB() external view returns (int256 deltaB);

    function poolCurrentDeltaB(address pool) external view returns (int256 deltaB);

    //function to mow all tokens for a given account.
    function mowAll(address account) external;

    function getOracleImplementationForToken(
        address token
    ) external view returns (Implementation memory);

    function updateOracleImplementationForToken(
        address token,
        Implementation memory impl
    ) external payable;

    function balanceOfRainRoots(address account) external view returns (uint256);

    function getSeasonStruct() external view returns (Season memory);

    function balanceOfPlenty(address account, address well) external view returns (uint256 plenty);

    function getDeposit(
        address account,
        address token,
        int96 stem
    ) external view returns (uint256, uint256);

    function calculateDeltaBFromReserves(
        address well,
        uint256[] memory reserves,
        uint256 lookback
    ) external view returns (int256);

    function getTokenDepositsForAccount(
        address account,
        address token
    ) external view returns (TokenDepositId memory deposits);
}
