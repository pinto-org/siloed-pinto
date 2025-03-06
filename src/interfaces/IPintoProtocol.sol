/**
 * SPDX-License-Identifier: MIT
 **/

pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

enum From {
    EXTERNAL,
    INTERNAL,
    EXTERNAL_INTERNAL,
    INTERNAL_TOLERANT
}
enum To {
    EXTERNAL,
    INTERNAL
}
enum ConvertKind {
    LAMBDA_LAMBDA,
    BEANS_TO_WELL_LP,
    WELL_LP_TO_BEANS,
    ANTI_LAMBDA_LAMBDA
}

interface IPintoProtocol {
    function season() external view returns (uint32);
    function balanceOfEarnedBeans(address account) external view returns (uint256 beans);
    function balanceOfGrownStalk(address account, address token) external view returns (uint256);
    function getGerminatingStem(address token) external view returns (int96 germinatingStem);
    function stemTipForToken(address token) external view returns (int96 _stemTip);

    function gm(address account, To mode) external payable returns (uint256);
    function sunrise() external payable returns (uint256);
    function mow(address account, address token) external payable;
    function plant() external payable returns (uint256 pinto, int96 stem);

    function deposit(
        address token,
        uint256 _amount,
        From mode
    ) external returns (uint256 amount, uint256 _bdv, int96 stem);

    function withdrawDeposits(
        address token,
        int96[] memory stems,
        uint256[] memory amounts,
        To mode
    ) external payable;

    function getInternalBalance(
        address account,
        IERC20 token
    ) external view returns (uint256 balance);

    function approveToken(address spender, IERC20 token, uint256 amount) external;

    function approveDeposit(address spender, address token, uint256 amount) external;

    function balanceOfPlenty(address account, address well) external view returns (uint256 plenty);

    function claimPlenty(address well, To toMode) external;

    function transferDeposits(
        address sender,
        address recipient,
        address token,
        int96[] calldata stems,
        uint256[] calldata amounts
    ) external payable returns (uint256[] memory bdvs);

    function transferToken(
        IERC20 token,
        address recipient,
        uint256 amount,
        From fromMode,
        To toMode
    ) external;

    function transferInternalTokenFrom(
        IERC20 token,
        address sender,
        address recipient,
        uint256 amount,
        To toMode
    ) external;

    function getWhitelistedWellLpTokens() external view returns (address[] memory tokens);
    function getNonBeanTokenAndIndexFromWell(address well) external view returns (address, uint256);

    function claimAllPlenty(
        To toMode
    ) external payable returns (ClaimPlentyData[] memory allPlenty);

    function getUsdTokenPrice(address token) external view returns (uint256);

    function convert(
        bytes memory convertData,
        int96[] memory stems,
        uint256[] memory amounts
    )
        external
        payable
        returns (
            int96 toStem,
            uint256 fromAmount,
            uint256 toAmount,
            uint256 fromBdv,
            uint256 toBdv
        );
}

struct ClaimPlentyData {
    address token;
    uint256 plenty;
}

struct Implementation {
    address target;
    bytes4 selector;
    bytes1 encodeType;
    bytes data;
}

struct Season {
    uint32 current;
    uint32 lastSop;
    uint32 lastSopSeason;
    uint32 rainStart;
    bool raining;
    uint64 sunriseBlock;
    bool abovePeg;
    uint256 start;
    uint256 period;
    uint256 timestamp;
    uint256 standardMintedBeans;
    bytes32[8] _buffer;
}

struct TokenDepositId {
    address token;
    uint256[] depositIds;
    Deposit[] tokenDeposits;
}

struct Deposit {
    uint128 amount;
    uint128 bdv;
}
