/**
 * SPDX-License-Identifier: MIT
 **/

pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPintoProtocol, From, To} from "src/interfaces/IPintoProtocol.sol";
import {SiloedPinto} from "src/SiloedPinto.sol";
import {ISiloedPinto} from "src/interfaces/ISiloedPinto.sol";
import "forge-std/console.sol";
import "openzeppelin-foundry-upgrades/Upgrades.sol";
import {TestHelpers} from "test/TestHelpers.sol";

contract SiloedPintoAdvancedTest is TestHelpers {
    
    function setUp() public {
        createForks();
        // fork when deltaP is negative to exclude earned pinto logic
        vm.selectFork(negativeDeltaPFork);
        // set the environment in the current fork
        _setUp();
    }
    ////////////////////////// Deposit Advanced //////////////////////////

    function testFuzz_depositAdvanced_ExternalInternal(
        uint256 actorSeed,
        uint256 assets
    ) public useActor(actorSeed) {
        assets = bound(assets, 1e6, MAX_PINTO);
        uint256 expectedShares = sPinto.previewDeposit(assets);

        depositAndCheckAdvanced(assets, From.EXTERNAL, To.INTERNAL);
        checkBalances(0, MAX_PINTO - assets, expectedShares, 0, user);
    }

    function testFuzz_depositAdvanced_InternalExternal(
        uint256 actorSeed,
        uint256 assets
    ) public useActor(actorSeed) {
        assets = bound(assets, 1e6, MAX_PINTO);
        uint256 expectedShares = sPinto.previewDeposit(assets);

        transferPintoToInternalBalance(assets, user);

        depositAndCheckAdvanced(assets, From.INTERNAL, To.EXTERNAL);

        checkBalances(0, MAX_PINTO - assets, 0, expectedShares, user);
    }

    function testFuzz_depositAdvanced_InternalInternal(
        uint256 actorSeed,
        uint256 assets
    ) public useActor(actorSeed) {
        assets = bound(assets, 1e6, MAX_PINTO);
        uint256 expectedShares = sPinto.previewDeposit(assets);

        transferPintoToInternalBalance(assets, user);

        depositAndCheckAdvanced(assets, From.INTERNAL, To.INTERNAL);

        checkBalances(0, MAX_PINTO - assets, expectedShares, 0, user);
    }

    ////////////////////////// Mint Advanced //////////////////////////

    function testFuzz_mintAdvanced_ExternalInternal(
        uint256 actorSeed,
        uint256 shares
    ) public useActor(actorSeed) {
        shares = bound(shares, 1e18, MAX_SPINTO);
        uint256 expectedAssets = sPinto.previewMint(shares);

        mintAndCheckAdvanced(shares, From.EXTERNAL, To.INTERNAL);

        checkBalances(0, MAX_PINTO - expectedAssets, shares, 0, user);
    }

    function testFuzz_mintAdvanced_InternalExternal(
        uint256 actorSeed,
        uint256 shares
    ) public useActor(actorSeed) {
        shares = bound(shares, 1e18, MAX_SPINTO);
        uint256 expectedAssets = sPinto.previewMint(shares);
        transferPintoToInternalBalance(expectedAssets, user);

        mintAndCheckAdvanced(shares, From.INTERNAL, To.EXTERNAL);

        checkBalances(0, MAX_PINTO - expectedAssets, 0, shares, user);
    }

    function testFuzz_mintAdvanced_InternalInternal(
        uint256 actorSeed,
        uint256 shares
    ) public useActor(actorSeed) {
        shares = bound(shares, 1e18, MAX_SPINTO);
        uint256 expectedAssets = sPinto.previewMint(shares);
        transferPintoToInternalBalance(expectedAssets, user);

        mintAndCheckAdvanced(shares, From.INTERNAL, To.INTERNAL);

        checkBalances(0, MAX_PINTO - expectedAssets, shares, 0, user);
    }

    ////////////////////////// Withdraw Advanced //////////////////////////

    function testFuzz_withdrawAdvanced_ExternalInternal(
        uint256 actorSeed,
        uint256 assets
    ) public useActor(actorSeed) {
        assets = bound(assets, 1e6, MAX_PINTO);
        // deposit and mint sPinto to user external balance
        depositAndCheckAdvanced(assets, From.EXTERNAL, To.EXTERNAL);

        withdrawAndCheckAdvanced(assets, From.EXTERNAL, To.INTERNAL);

        checkBalances(assets, MAX_PINTO - assets, 0, 0, user);
    }

    function testFuzz_withdrawAdvanced_InternalExternal(
        uint256 actorSeed,
        uint256 assets
    ) public useActor(actorSeed) {
        assets = bound(assets, 1e6, MAX_PINTO);
        // deposit and mint sPinto to user internal balance
        depositAndCheckAdvanced(assets, From.EXTERNAL, To.INTERNAL);

        withdrawAndCheckAdvanced(assets, From.INTERNAL, To.EXTERNAL);

        // all assets back to external balance
        checkBalances(0, MAX_PINTO, 0, 0, user);
    }

    function testFuzz_withdrawAdvanced_InternalInternal(
        uint256 actorSeed,
        uint256 assets
    ) public useActor(actorSeed) {
        assets = bound(assets, 1e6, MAX_PINTO);
        // deposit and mint sPinto to user internal balance
        depositAndCheckAdvanced(assets, From.EXTERNAL, To.INTERNAL);

        withdrawAndCheckAdvanced(assets, From.INTERNAL, To.INTERNAL);

        checkBalances(assets, MAX_PINTO - assets, 0, 0, user);
    }

    ////////////////////////// Redeem Advanced //////////////////////////

    function testFuzz_redeemAdvanced_ExternalInternal(
        uint256 actorSeed,
        uint256 assets
    ) public useActor(actorSeed) {
        assets = bound(assets, 1e6, MAX_PINTO);
        uint256 expectedShares = sPinto.previewDeposit(assets);
        // deposit and mint sPinto to user external balance
        depositAndCheckAdvanced(assets, From.EXTERNAL, To.EXTERNAL);

        redeemAndCheckAdvanced(expectedShares, From.EXTERNAL, To.INTERNAL);

        checkBalances(assets, MAX_PINTO - assets, 0, 0, user);
    }

    function testFuzz_redeemAdvanced_InternalExternal(
        uint256 actorSeed,
        uint256 assets
    ) public useActor(actorSeed) {
        assets = bound(assets, 1e6, MAX_PINTO);
        uint256 expectedShares = sPinto.previewDeposit(assets);
        // deposit and mint sPinto to user internal balance
        depositAndCheckAdvanced(assets, From.EXTERNAL, To.INTERNAL);

        redeemAndCheckAdvanced(expectedShares, From.INTERNAL, To.EXTERNAL);

        // all assets back to external balance
        checkBalances(0, MAX_PINTO, 0, 0, user);
    }

    function testFuzz_redeemAdvanced_InternalInternal(
        uint256 actorSeed,
        uint256 assets
    ) public useActor(actorSeed) {
        assets = bound(assets, 1e6, MAX_PINTO);
        uint256 expectedShares = sPinto.previewDeposit(assets);
        // deposit and mint sPinto to user internal balance
        depositAndCheckAdvanced(assets, From.EXTERNAL, To.INTERNAL);

        redeemAndCheckAdvanced(expectedShares, From.INTERNAL, To.INTERNAL);

        checkBalances(assets, MAX_PINTO - assets, 0, 0, user);
    }

    ////////////////////////// Helpers //////////////////////////

    function transferPintoToInternalBalance(uint256 amount, address user) public {
        // approve the diamond to pull Pinto from the caller
        pinto.approve(PINTO_PROTOCOL, amount);
        vm.startPrank(user);
        // deposit 100e18 Pinto to internal balance to use for mint
        pintoProtocol.transferToken(pinto, user, amount, From.EXTERNAL, To.INTERNAL);
        // approve sPinto to spend Pinto from internal balance
        pintoProtocol.approveToken(address(sPinto), pinto, amount);
        vm.stopPrank();
    }
}
