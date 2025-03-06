/**
 * SPDX-License-Identifier: MIT
 **/

pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";
import {IPintoProtocol, From, To} from "src/interfaces/IPintoProtocol.sol";
import {IWell} from "test/interfaces/IWell.sol";
import {ISiloedPinto} from "src/interfaces/ISiloedPinto.sol";
import {SiloedPinto} from "src/SiloedPinto.sol";
import {TestHelpers} from "test/TestHelpers.sol";
import "forge-std/console.sol";

contract SiloedPintoBaseFuzzTest is TestHelpers {
    function setUp() public {
        createForks();
        // fork when deltaP is negative to exclude earned pinto logic
        vm.selectFork(negativeDeltaPFork);
        // set the environment in the current fork
        _setUp();
    }

    ////////////////// DEPOSIT/MINT //////////////////

    // Deposit
    function testFuzz_deposit_one(uint256 assets, uint256 actorSeed) public useActor(actorSeed) {
        assets = bound(assets, MIN_SIZE, pinto.balanceOf(user));

        depositAndCheck(assets);
    }

    function testFuzz_deposit_many(
        uint256[] memory assets,
        uint256 actorSeed
    ) public useActor(actorSeed) {
        for (uint256 i = 0; i < assets.length; i++) {
            uint256 balance = pinto.balanceOf(user);
            if (balance < MIN_SIZE) return;
            uint256 depositAmount = bound(assets[i], MIN_SIZE, balance);

            depositAndCheck(depositAmount);
        }
    }

    function testFuzz_mint_one(uint256 shares, uint256 actorSeed) public useActor(actorSeed) {
        shares = bound(
            shares,
            sPinto.convertToShares(MIN_SIZE),
            sPinto.convertToShares(pinto.balanceOf(user))
        );

        mintAndCheck(shares);
    }

    function testFuzz_mint_many(
        uint256[] memory shares,
        uint256 actorSeed
    ) public useActor(actorSeed) {
        for (uint256 i = 0; i < shares.length; i++) {
            uint256 sharesFromBalance = sPinto.convertToShares(pinto.balanceOf(user));
            uint256 minShares = sPinto.convertToShares(MIN_SIZE);
            if (sharesFromBalance < minShares) return;
            uint256 shareAmount = bound(shares[i], minShares, sharesFromBalance);

            mintAndCheck(shareAmount);
        }
    }

    ////////////////// REDEEM/WITHDRAW //////////////////

    function testFuzz_withdraw_one(uint256 assets, uint256 actorSeed) public useActor(actorSeed) {
        assets = bound(assets, 1, type(uint32).max);
        dealSPinto(user, sPinto.convertToShares(assets));

        withdrawAndCheck(assets);
    }

    function testFuzz_redeem_one(uint256 shares, uint256 actorSeed) public useActor(actorSeed) {
        shares = bound(shares, sPinto.convertToShares(1), sPinto.convertToShares(type(uint32).max));
        dealSPinto(user, shares);

        redeemAndCheck(shares);
    }

    ////////////////// CLAIM //////////////////

    function testFuzz_claim_one(int256 deltaPMagnitude) public {
        deltaPMagnitude = bound(deltaPMagnitude, -1e18, 1e18);

        // Give sPinto some germinated stalk.
        sPinto.deposit(1000e6, BIN);
        proceedAndGm();
        proceedAndGm();

        setDeltaPApproximate(deltaPMagnitude);
        proceedAndGm();

        int256 newDeltaP = pintoProtocol.totalDeltaB();
        console.log("deltaPMagnitude: %d", deltaPMagnitude);
        console.log("new DeltaP: %d", newDeltaP);

        if (deltaPMagnitude > 0) {
            assertGt(pintoProtocol.balanceOfEarnedBeans(address(sPinto)), 0, "no earned");
        }
        claimAndCheck();
    }

    function testFuzz_claim_many(int256[5] memory deltaPMagnitudes) public {
        // Give sPinto some germinated stalk.
        sPinto.deposit(1000e6, BIN);
        proceedAndGm();
        proceedAndGm();

        for (uint256 i = 0; i < deltaPMagnitudes.length; i++) {
            int256 deltaPMagnitude = bound(deltaPMagnitudes[i], -1e18, 1e18);

            setDeltaPApproximate(deltaPMagnitude);
            proceedAndGm();

            int256 newDeltaP = pintoProtocol.totalDeltaB();
            console.log("deltaPMagnitude: %d", deltaPMagnitude);
            console.log("new DeltaP: %d", newDeltaP);

            if (deltaPMagnitude > 0) {
                assertGt(pintoProtocol.balanceOfEarnedBeans(address(sPinto)), 0, "no earned");
            }
            claimAndCheck();
        }
    }

        function testFuzz_germinatingDeposits(
        uint256[10] memory amounts,
        uint256[10] memory seeds
    ) public {
        // Give sPinto some germinated stalk.
        sPinto.deposit(1000e6, BIN);
        proceedAndGm();
        proceedAndGm();

        uint256 sum = 0;

        for (uint256 i = 0; i < amounts.length; i++) {
            _useActor(seeds[i]);
            uint256 amount = bound(amounts[i], 1e6, 1000e6);
            sPinto.deposit(amount, BIN);
            if (i % 3 == 0) proceedAndGm();
            if (i % 5 == 0) sPinto.claim();
            sum += amount;
        }

        // assert that the lenght of the germinating deposits is max 2
        assertLt(
            sPinto.getGerminatingDepositsLength(),
            3,
            "germinating deposits length should be max 2"
        );

        // assert that underlying pdv is the sum of the amounts
        // plus the initial deposit
        assertEq(sPinto.underlyingPdv(), sum + 1000e6);
    }

    function testFuzz_mix(
        uint256[10] memory amounts,
        uint256[10] memory actorSeeds,
        uint256[10] memory actionSeeds,
        int256[10] memory deltaPMagnitudes
    ) public {
        // Give sPinto some germinated stalk.
        sPinto.deposit(1000e6, BIN);
        proceedAndGm();
        proceedAndGm();

        for (uint256 i = 0; i < 10; i++) {
            _useActor(actorSeeds[i]);

            uint256 amount;
            uint256 actionSeed = bound(actionSeeds[i], 0, 5);
            if (actionSeed == 0) {
                uint256 balance = pinto.balanceOf(user);
                if (balance < 1e6) continue;
                amount = bound(amounts[i], 1e6, pinto.balanceOf(user));
                depositAndCheck(amount);
            } else if (actionSeed == 1) {
                uint256 maxMint = sPinto.previewMint(pinto.balanceOf(user));
                if (maxMint < 1e18) continue;
                amount = bound(amounts[i], 1e18, maxMint);
                mintAndCheck(amount);
            } else if (actionSeed == 2) {
                uint256 maxWithdraw = sPinto.getMaxWithdraw(user, From.EXTERNAL);
                if (maxWithdraw == 0) continue;
                amount = bound(amounts[i], 1, maxWithdraw);
                withdrawAndCheck(amount);
            } else if (actionSeed == 3) {
                uint256 maxRedeem = sPinto.getMaxRedeem(user, From.EXTERNAL);
                if (maxRedeem < 1e12) continue;
                amount = bound(amounts[i], 1e12, maxRedeem); // 1e0 Pinto min
                redeemAndCheck(amount);
            } else {
                claimAndCheck();
            }

            if (i % 3 == 0) {
                // address[] memory wells = pintoProtocol.getWhitelistedWellLpTokens();
                int256 deltaPMagnitude = bound(deltaPMagnitudes[i], -1e18, 1e18);
                setDeltaPApproximate(deltaPMagnitude);
                // NOTE: Running this many times with -vvv will cause memory overflow and kill the test.
                proceedAndGm();

                int256 newDeltaP = pintoProtocol.totalDeltaB();
                console.log("deltaPMagnitude: %d", deltaPMagnitude);
                console.log("new DeltaP: %d", newDeltaP);
                if (deltaPMagnitude > 0) {
                    assertGt(pintoProtocol.balanceOfEarnedBeans(address(sPinto)), 0, "no earned");
                }
            }
        }
    }
}
