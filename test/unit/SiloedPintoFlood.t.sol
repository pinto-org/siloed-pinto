/**
 * SPDX-License-Identifier: MIT
 **/

pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";
import {IWell} from "test/interfaces/IWell.sol";
import {IPintoProtocolExtended, From, To, Implementation, Season} from "test/interfaces/IPintoProtocolExtended.sol";
import {SiloedPinto} from "src/SiloedPinto.sol";
import {ISiloedPinto} from "src/interfaces/ISiloedPinto.sol";
import "forge-std/console.sol";
import "openzeppelin-foundry-upgrades/Upgrades.sol";
import {TestHelpers} from "test/TestHelpers.sol";

contract SiloedPintoFloodTest is TestHelpers {
    function setUp() public {
        createForks();
        // fork when flooding all assets
        vm.selectFork(preFloodFork);
        // set the environment in the current fork
        _setUp();

        // do a deposit to get underlying in sPinto
        uint256 assets = 100_000e6;
        sPinto.deposit(assets, actors[0]);

        // pass germination
        proceedAndGm();
        proceedAndGm();
    }

    /**
     * @notice Tests claiming of flood assets but skipping swappiung due to price slippage
     */
    function test_claimFloodAssetsNoSwap() public {
        // flood a lot, claim and skip vesting
        bigFloodSetupAndClaim();

        // check flood assets in sPinto balance
        for (uint256 i = 0; i < wells.length; i++) {
            IWell well = IWell(wells[i]);
            (address tokenAddr, ) = pintoProtocol.getNonBeanTokenAndIndexFromWell(address(well));
            IERC20 token = IERC20(tokenAddr);
            uint256 balance = token.balanceOf(address(sPinto));
            uint256 balanceOfWellPlenty = pintoProtocol.balanceOfPlenty(
                address(sPinto),
                address(well)
            );
            assertGt(balance, 0, "balance of flood asset should be gt 0");
            assertEq(balanceOfWellPlenty, 0, "plenty for well not claimed");
        }
    }

    /**
     * @notice Tests that no swaps occur when price is above threshold
     */
    function test_skipFloodSwapIfPriceAboveThreshold() public {
        // flood a lot, claim and skip vesting
        bigFloodSetupAndClaim();

        // store pre flood swap balances
        uint256[] memory preSwapBalances = new uint256[](wells.length);
        for (uint256 i = 0; i < floodTokens.length; i++) {
            preSwapBalances[i] = floodTokens[i].balanceOf(address(sPinto));
            assertGt(preSwapBalances[i], 0, "flood asset balance should be gt 0");
            // assert that indeed rates are negative and not close enough
        }

        // add liquid to all wells to get price above threshold but not call gm to flood
        addInvalidPriceLiquidityToAllWells(actors[0]);
        vm.warp(block.timestamp + 100);

        // assert that deltaps are not close enough
        for (uint256 i = 0; i < wells.length; i++) {
            assertFalse(
                isValidMaxPrice(IWell(wells[i]), floodTokens[i], MAX_TRIGGER_PRICE),
                "well price should be above threshold"
            );
        }

        // call claim again and assert that no balaces have been swapped
        // since price is too high
        sPinto.claim();

        for (uint256 i = 0; i < floodTokens.length; i++) {
            assertEq(
                floodTokens[i].balanceOf(address(sPinto)),
                preSwapBalances[i],
                "flood asset balance should not change due to invalid price"
            );
        }
    }

    /**
     * @notice Tests that no swaps occur when price below threshold
     * but slippage between instant and current rate is too high
     */
    function test_skipFloodSwapIfPriceValidAndSlippageInvalid() public {
        // flood a lot, claim and skip vesting
        bigFloodSetupAndClaim();

        // store pre flood swap balances
        uint256[] memory preSwapBalances = new uint256[](wells.length);
        for (uint256 i = 0; i < floodTokens.length; i++) {
            preSwapBalances[i] = floodTokens[i].balanceOf(address(sPinto));
            assertGt(preSwapBalances[i], 0, "flood asset balance should be gt 0");
        }

        // add single sided pinto to draw price down below threshold to isolate slippage
        addAntiFloodLiquidityToAllWells(actors[0]);
        // make some time pass but not enough so that ema price does not catch up to current price
        vm.warp(block.timestamp + 10);

        // assert that deltaps are not close enough
        for (uint256 i = 0; i < wells.length; i++) {
            assertFalse(
                isValidSlippage(IWell(wells[i]), floodTokens[i], SLIPPAGE_RATIO),
                "well prices should have too high slippage"
            );
        }

        // call claim again and assert that no balaces have been swapped
        sPinto.claim();

        for (uint256 i = 0; i < floodTokens.length; i++) {
            assertEq(
                floodTokens[i].balanceOf(address(sPinto)),
                preSwapBalances[i],
                "flood asset balance should not change due to invalid prices"
            );
        }
    }

    /**
     * @notice Tests that no swaps occur when price below threshold
     * but current price to ema price in some wells
     */
    function test_FloodTrancheAmountSomeWells() public {
        // flood a lot, claim and skip vesting
        bigFloodSetupAndClaim();

        // store pre flood swap balances
        uint256[] memory preSwapBalances = new uint256[](wells.length);
        uint256[] memory trancheAmounts = new uint256[](wells.length);
        for (uint256 i = 0; i < floodTokens.length; i++) {
            preSwapBalances[i] = floodTokens[i].balanceOf(address(sPinto));
            trancheAmounts[i] = (preSwapBalances[i] * FLOOD_TRANCH_RATIO) / 1e18;
            assertGt(preSwapBalances[i], 0, "flood asset balance should be gt 0");
        }

        // make prive invalid for weth, wsol and usdc well (i = 0, 3, 4)
        addInvalidPriceLiquidityToSomeWells(actors[0]);
        // make time pass so that ema price catches up to current price
        vm.warp(block.timestamp + 100000);

        // call claim again and assert that balances for weth and usdc wells have not been swapped
        sPinto.claim();

        for (uint256 i = 0; i < floodTokens.length; i++) {
            if (i == 0 || i == 3 || i == 4) {
                assertEq(
                    floodTokens[i].balanceOf(address(sPinto)),
                    preSwapBalances[i],
                    "flood asset balance should not change due to invalid price"
                );
            } else {
                assertEq(
                    floodTokens[i].balanceOf(address(sPinto)),
                    preSwapBalances[i] - trancheAmounts[i],
                    "flood asset balance should decrease by tranche amount"
                );
            }
        }
    }

    /**
     * @notice Tests that the `trancheAmount` of flood assets is swapped when price is valid
     * and prices are close enough in all wells
     */
    function test_FloodSwapTrancheAmountAllWellsPartial() public {
        // flood a lot, claim and skip vesting
        bigFloodSetupAndClaim();

        // pre deposit length
        uint256 preSwapDepositLength = sPinto.getDepositsLength();

        // store pre flood swap balances
        uint256[] memory preSwapBalances = new uint256[](wells.length);
        uint256[] memory trancheAmounts = new uint256[](wells.length);

        for (uint256 i = 0; i < floodTokens.length; i++) {
            preSwapBalances[i] = floodTokens[i].balanceOf(address(sPinto));
            trancheAmounts[i] = (preSwapBalances[i] * FLOOD_TRANCH_RATIO) / 1e18;
            assertGt(preSwapBalances[i], 0, "flood asset balance should be gt 0");
        }

        // add single sided pinto to draw price down below threshold to isolate prices
        addAntiFloodLiquidityToAllWells(actors[0]);
        // make time pass so that ema price catches up to current price
        vm.warp(block.timestamp + 100000);

        // call claim again and assert that no balaces have been swapped
        sPinto.claim();

        for (uint256 i = 0; i < floodTokens.length; i++) {
            assertEq(
                floodTokens[i].balanceOf(address(sPinto)),
                preSwapBalances[i] - trancheAmounts[i],
                "flood asset balance should decrease by tranche amount"
            );
        }

        // assert that the length of deposits is now 3 from depositing all the pinto in
        assertEq(
            sPinto.getDepositsLength(),
            preSwapDepositLength + 1,
            "deposit length should increase by 1"
        );
    }

    /**
     * @notice Tests that the `trancheAmount` of flood assets is swapped when price is valid
     * and prices are close enough in all wells until all flood assets are swapped
     * note: dust amounts require an extra claim
     */
    function test_FloodSwapTrancheAmountAllWellsFull() public {
        // flood a lot, claim and skip vesting
        bigFloodSetupAndClaim();

        // pre deposit length
        uint256 preSwapDepositLength = sPinto.getDepositsLength();

        // store pre flood swap balances
        uint256[] memory preSwapBalances = new uint256[](wells.length);
        for (uint256 i = 0; i < floodTokens.length; i++) {
            preSwapBalances[i] = floodTokens[i].balanceOf(address(sPinto));
            assertGt(preSwapBalances[i], 0, "flood asset balance should be gt 0");
        }

        // add single sided pinto to draw price down below threshold to isolate deltaPs
        addAntiFloodLiquidityToAllWells(actors[0]);
        // make time pass so that ema deltab catches up to current deltab
        vm.warp(block.timestamp + 100000);

        // tranch ratio is 10% of flood asset balance so we can call claim 10 times + 1 for dust amounts
        for (uint256 i = 0; i < 11; i++) {
            // call claim again and assert that no balances have been swapped
            sPinto.claim();
            // make time pass so that ema price catches up to current price
            proceedAndGm();
        }

        // all post swap balances should be 0
        for (uint256 i = 0; i < floodTokens.length; i++) {
            assertEq(
                floodTokens[i].balanceOf(address(sPinto)),
                0,
                "flood asset balance should be 0 after all swaps"
            );
        }

        // assert that the length of deposits is now 11
        assertEq(
            sPinto.getDepositsLength(),
            preSwapDepositLength + 11,
            "deposit length should increase by 11"
        );
    }

    /**
     * @notice Tests that the `trancheAmount` of flood assets is adjusted when 2 consecutive floods occur
     */
    function test_TranchesAdjustOnTwoConsecutiveFloods() public {
        // flood a lot, claim and skip vesting
        bigFloodSetupAndClaim();

        // store pre flood swap balances
        uint256[] memory preBalances = new uint256[](wells.length);
        for (uint256 i = 0; i < floodTokens.length; i++) {
            preBalances[i] = floodTokens[i].balanceOf(address(sPinto));
            assertGt(preBalances[i], 0, "flood asset balance should be gt 0");
        }

        // claim and swap with init tranches
        sPinto.claim();
        uint256[] memory initTrancheSizes = new uint256[](wells.length);
        for (uint256 i = 0; i < floodTokens.length; i++) {
            initTrancheSizes[i] = (preBalances[i] * FLOOD_TRANCH_RATIO) / 1e18;
            assertEq(sPinto.trancheSizes(address(floodTokens[i])), initTrancheSizes[i]);
        }

        addSmallFloodLiquidityToAllWells(actors[0]);
        // season of rain
        proceedAndGm();
        // flood
        proceedAndGm();
        // make time pass so that ema price catches up to current price
        vm.warp(block.timestamp + 100000);

        // claim and swap with new tranches
        sPinto.claim();
        for (uint256 i = 0; i < floodTokens.length; i++) {
            assertGt(
                sPinto.trancheSizes(address(floodTokens[i])),
                initTrancheSizes[i],
                "tranche sizes should increase"
            );
        }
    }

    /**
     * @notice Tests that reserves are updated before claiming flood assets,
     * eliminating the chance of them being stale.
     */
    function test_FloodSwapSlippageInvalidIfLiquidityIsModifiedBeforeClaim() public {
        // flood a lot, claim and skip vesting
        bigFloodSetupAndClaim();

        // store pre flood swap balances
        uint256[] memory preBalances = new uint256[](wells.length);
        for (uint256 i = 0; i < floodTokens.length; i++) {
            preBalances[i] = floodTokens[i].balanceOf(address(sPinto));
            assertGt(preBalances[i], 0, "flood asset balance should be gt 0");
        }

        // make 6 hours pass (no swaps, updates to the pump occur)
        skipVesting();
        skipVesting();
        skipVesting();
        // add small flood liquidity to all wells but dont update reserves
        // so that they are stale. If LibPrice doesn't call sync, then the swaps go through
        addSmallFloodLiquidityToAllWellsNoSync();

        // claim and try to swap
        sPinto.claim();

        // verify that no swaps occur since we have synced the reserves
        for (uint256 i = 0; i < floodTokens.length; i++) {
            assertEq(
                floodTokens[i].balanceOf(address(sPinto)),
                preBalances[i],
                "flood asset balance should not change"
            );
        }
    }

    // //////////////////// Helper functions ////////////////////

    function bigFloodSetupAndClaim() public {
        // add liquidity to all wells to get a lot of plenty for all
        addFloodLiquidityToAllWells(actors[0]);
        floodAndClaim();
    }

    function smallFloodSetupAndClaim() public {
        // add liquidity to all wells to get a lot of plenty for all
        addSmallFloodLiquidityToAllWells(actors[0]);
        floodAndClaim();
    }

    function floodAndClaim() public {
        // season of rain
        proceedAndGm();
        // flood
        proceedAndGm();

        // ensure a flood has occured
        Season memory season = pintoProtocol.getSeasonStruct();
        assertEq(season.lastSopSeason, season.current, "current season not sop season");

        // claim flood assets
        sPinto.claim();
        proceedAndGm();
        // skip vesting so that underlyingPdv == totalAssets
        skipVesting();
    }
}
