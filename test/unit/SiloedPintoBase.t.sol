/**
 * SPDX-License-Identifier: MIT
 **/

pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";
import {IWell} from "test/interfaces/IWell.sol";
import {IPintoProtocolExtended, From, To, Implementation} from "test/interfaces/IPintoProtocolExtended.sol";
import {SiloedPinto} from "src/SiloedPinto.sol";
import {ISiloedPinto, SiloDeposit} from "src/interfaces/ISiloedPinto.sol";
import "forge-std/console.sol";
import "openzeppelin-foundry-upgrades/Upgrades.sol";
import {TestHelpers} from "test/TestHelpers.sol";
import {AbstractSiloedPinto} from "src/AbstractSiloedPinto.sol";

contract SiloedPintoBaseTest is TestHelpers {
    function setUp() public {
        createForks();
        // fork when deltaP is negative to exclude earned pinto logic
        vm.selectFork(negativeDeltaPFork);
        // set the environment in the current fork
        _setUp();
    }

    /////////////////// Redeem Multiple Logic ///////////////////

    function test_redeemMultipleDeposits() public {
        // intitial deposit
        uint256 initialDeposit = 10_001e6;
        uint256 initialSupply = 10_001e18;
        sPinto.deposit(initialDeposit, address(this));
        assertEq(sPinto.totalSupply(), initialSupply);
        // deposit multiple times at different stems and redeem an amount that will
        // redeem some deposits from the list and then a partial amount from the last deposit
        vm.pauseGasMetering();
        for (uint256 i = 2; i < 7; i++) {
            // call sunrise on the protocol to update stems
            // pass germination for all
            proceedAndGm();
            proceedAndGm();
            sPinto.claim();
            sPinto.deposit(i * 10_000e6, address(this));
        }

        // pass germination for all
        proceedAndGm();
        proceedAndGm();
        // claim and move germinating deposits to regular deposits list
        sPinto.claim();

        // Snapshot State:
        // - deposits = [10000 20000 30000 40000 50000 60000]
        // - totalSupply: 210_000e18
        uint256 totalSupplyOld = sPinto.totalSupply();
        // - underlyingPdv: 210_000e6
        uint256 underlyingPdvOld = sPinto.underlyingPdv();
        // - balanceOf: 210_000e18
        uint256 sPintoBalanceBefore = sPinto.balanceOf(address(this));

        // calculate the amount of pinto that should be redeemed
        uint256 calcPintoOut = sPinto.previewRedeem(150_000e18);

        // try to redeem 150_000e18 sPinto tokens for pinto
        uint256 pintoOut = sPinto.redeem(150_000e18, address(this), address(this));

        // verify that the amount of pinto redeemed is correct
        assertEq(pintoOut, calcPintoOut);
        // verify that the underlyingPdv has decreased by the amount of pinto redeemed
        assertEq(sPinto.underlyingPdv(), underlyingPdvOld - pintoOut);
        // verify that the length of deposits is 3
        // [10000 20000 30000 40000 50000 60000] -> [10000 20000 30000]
        assertEq(sPinto.getDepositsLength(), 3);
        // verify that the totalSupply is reduced by 1000
        assertEq(sPinto.totalSupply(), totalSupplyOld - 150_000e18);
        // verify that the balance of the contract is 600
        assertEq(sPinto.balanceOf(address(this)), sPintoBalanceBefore - 150_000e18);
    }

    /////////////////// Push deposit Logic ///////////////////

    function test_pushDeposit() public {
        // 1st case: deposits is empty
        // push 1 deposit and verify that the length of the array is 1
        // state [1]
        mockPushDeposit(1);
        assertEq(mockDeposits.length, 1);

        // 2nd case: deposits has 1 element and we try to push the same element
        // push the same deposit and verify that the length of the array is still 1
        // state [1]
        mockPushDeposit(1);
        assertEq(mockDeposits.length, 1);

        // 3rd case: deposits has 1 element
        // push until there are 10 deposits with an increasing order
        // state [1 2 3 4 5 6 7 8 9 10]
        for (int96 i = 2; i < 11; i++) {
            mockPushDeposit(i);
        }
        // verify that the length of the array is 10
        assertEq(mockDeposits.length, 10);
        // verify that the array is ordered
        for (uint256 i = 1; i < mockDeposits.length; i++) {
            assertLt(mockDeposits[i - 1], mockDeposits[i]);
        }

        // add a deposit that is greater than the last element to set up the next case
        mockPushDeposit(12);
        // verify that the length of the array is 11
        assertEq(mockDeposits.length, 11);

        // 4th case: deposits has 11 elements and we try to push a deposit that is lower than the last element
        // resulting state: [1 2 3 4 5 6 7 8 9 10 11 12]
        mockPushDeposit(11);
        // verify that the length of the array is 12
        assertEq(mockDeposits.length, 12);
        // verify that the array is ordered
        for (uint256 i = 1; i < mockDeposits.length; i++) {
            assertLt(mockDeposits[i - 1], mockDeposits[i]);
        }

        // Edge case: push 0 to the list (the lowest number)
        mockPushDeposit(0);
        // verify that the length of the array is 13
        assertEq(mockDeposits.length, 13);
        // verify that the array is ordered
        // resulting state: [0 1 2 3 4 5 6 7 8 9 10 11 12]
        for (uint256 i = 1; i < mockDeposits.length; i++) {
            assertLt(mockDeposits[i - 1], mockDeposits[i]);
        }
    }

    /////////////////// Claim Simple Earned Pinto and Vest Logic ///////////////////

    function test_claimAndVest() public {
        // Give sPinto some germinated stalk.
        user = actors[0];
        depositAndCheck(1000e6);
        assertEq(sPinto.getDepositsLength(), 1);
        proceedAndGm();

        // add liquidity to the PINTO:WETH well to make deltaP positive
        address[] memory wells = pintoProtocol.getWhitelistedWellLpTokens();
        setLiquidityInWell(user, wells[0], 1000e6, 10000000e18);

        // pass germination for all
        proceedAndGm();
        proceedAndGm();

        assertGt(pintoProtocol.balanceOfEarnedBeans(address(sPinto)), 0, "no earned");

        uint256 season = pintoProtocol.season();
        uint256 earnedPinto = pintoProtocol.balanceOfEarnedBeans(address(sPinto));
        uint256 initialAssets = sPinto.totalAssets();
        sPinto.claim();
        assertEq(pintoProtocol.season(), season, "check incompatible with sunrise");
        assertEq(pinto.balanceOf(address(sPinto)), 0, "invalid external balance");
        assertEq(
            pintoProtocol.getInternalBalance(address(sPinto), pinto),
            0,
            "invalid internal balance"
        );

        // assert that the lenght of deposits is 1 since the earned pinto deposit is l2l merged with initial
        assertEq(sPinto.getDepositsLength(), 1);
        assertEq(sPinto.getGerminatingDepositsLength(), 0);

        // assert that this deposit amount is equal to original deposit + earned pinto
        (, uint160 amount) = sPinto.deposits(0);
        assertEq(amount, initialAssets + earnedPinto);

        /////////////////// Earned Pinto Vesting ///////////////////

        // check vesting in 10 minute intervals up to 2hrs
        checkVestingInIntervals(initialAssets, earnedPinto, 10, false);
    }

    /////////////////// Revert tests ///////////////////

    ////////////////////// ERC4626ExceededMaxRedeem //////////////////////

    function test_RevertIfRedeemMoreThanBalanceExternal() public useActor(0) {
        uint256 assets = 1000e6;
        uint256 expectedShares = sPinto.convertToShares(assets);
        depositAndCheckAdvanced(assets, From.EXTERNAL, To.EXTERNAL);
        // try to redeem more shares than the user has
        vm.expectPartialRevert(ISiloedPinto.ERC4626ExceededMaxRedeem.selector);
        sPinto.redeem(expectedShares + 1, user, user);
    }

    function test_RevertIfRedeemMoreThanBalanceInternal() public useActor(0) {
        uint256 assets = 1000e6;
        uint256 expectedShares = sPinto.convertToShares(assets);
        depositAndCheckAdvanced(assets, From.EXTERNAL, To.INTERNAL);
        // try to redeem more shares than the user has
        vm.expectPartialRevert(ISiloedPinto.ERC4626ExceededMaxRedeem.selector);
        sPinto.redeemAdvanced(expectedShares + 1, user, user, From.INTERNAL, To.INTERNAL);
    }

    ///////////////////// ERC4626ExceededMaxWithdraw ////////////////////////

    function test_RevertIfWithdrawMoreThanBalanceExternal() public useActor(0) {
        uint256 assets = 1000e6;
        depositAndCheckAdvanced(assets, From.EXTERNAL, To.EXTERNAL);
        // try to withdraw more assets than the user's shares cover
        vm.expectPartialRevert(ISiloedPinto.ERC4626ExceededMaxWithdraw.selector);
        sPinto.withdraw(assets + 1, user, user);
    }

    function test_RevertIfWithdrawMoreThanBalanceInternal() public useActor(0) {
        uint256 assets = 1000e6;
        depositAndCheckAdvanced(assets, From.EXTERNAL, To.INTERNAL);
        // try to withdraw more assets than the user's shares cover
        vm.expectPartialRevert(ISiloedPinto.ERC4626ExceededMaxWithdraw.selector);
        sPinto.withdrawAdvanced(assets + 1, user, user, From.INTERNAL, To.INTERNAL);
    }

    ///////////////////// ZeroAssets, ZeroShares ////////////////////////

    function test_RevertZeroAssets() public useActor(0) {
        // try to deposit
        vm.expectPartialRevert(ISiloedPinto.ZeroAssets.selector);
        sPinto.deposit(0, user);
        // try to mint 0 shares, it calls previewMint that returns assets
        // and assets are checked first so the revert will be ZeroAssets
        vm.expectPartialRevert(ISiloedPinto.ZeroAssets.selector);
        sPinto.mint(0, user);
        // try to redeem 0 shares, it calls previewRedeem that returns assets
        // and assets are checked first so the revert will be ZeroAssets
        vm.expectPartialRevert(ISiloedPinto.ZeroAssets.selector);
        sPinto.redeem(0, user, user);
        // try to withdraw 0 assets
        vm.expectPartialRevert(ISiloedPinto.ZeroAssets.selector);
        sPinto.withdraw(0, user, user);
    }

    function test_RevertZeroAssetsAdvanced() public useActor(0) {
        // try to deposit
        vm.expectPartialRevert(ISiloedPinto.ZeroAssets.selector);
        sPinto.depositAdvanced(0, user, From.EXTERNAL, To.EXTERNAL);
        // try to mint 0 shares, it calls previewMint that returns assets
        // and assets are checked first so the revert will be ZeroAssets
        vm.expectPartialRevert(ISiloedPinto.ZeroAssets.selector);
        sPinto.mintAdvanced(0, user, From.EXTERNAL, To.EXTERNAL);
        // try to redeem 0 shares, it calls previewRedeem that returns assets
        // and assets are checked first so the revert will be ZeroAssets
        vm.expectPartialRevert(ISiloedPinto.ZeroAssets.selector);
        sPinto.redeemAdvanced(0, user, user, From.EXTERNAL, To.EXTERNAL);
        // try to withdraw 0 assets
        vm.expectPartialRevert(ISiloedPinto.ZeroAssets.selector);
        sPinto.withdrawAdvanced(0, user, user, From.EXTERNAL, To.EXTERNAL);
    }

    function test_RevertZeroAssetsWithdrawToSilo() public useActor(0) {
        uint256 assets = 100e6;
        // deposit and mint sPinto to receiver external balance
        sPinto.depositAdvanced(assets, receiver, From.EXTERNAL, To.EXTERNAL);
        vm.expectPartialRevert(ISiloedPinto.ZeroAssets.selector);
        sPinto.withdrawToSilo(0, receiver, receiver, From.EXTERNAL);
    }

    function test_RevertZeroAssetsRedeemToSilo() public useActor(0) {
        uint256 assets = 100e6;
        // deposit and mint sPinto to receiver external balance
        sPinto.depositAdvanced(assets, receiver, From.EXTERNAL, To.EXTERNAL);
        vm.expectPartialRevert(ISiloedPinto.ZeroAssets.selector);
        sPinto.redeemToSilo(0, receiver, receiver, From.EXTERNAL);
    }

    function test_RevertZeroAssetsDepositFromSilo() public useActor(0) {
        // deposit and mint sPinto using the silo deposits
        int96[] memory stems = new int96[](1);
        stems[0] = 0;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 0;
        vm.expectPartialRevert(ISiloedPinto.ZeroAssets.selector);
        sPinto.depositFromSilo(stems, amounts, receiver, To.EXTERNAL);
    }

    ///////////////////// MinPdvViolation ////////////////////////

    function test_RevertMinPdvViolation() public useActor(0) {
        // deposit less than the set minimum pdv in
        uint256 assets = 1;

        // deposit
        vm.expectPartialRevert(ISiloedPinto.MinPdvViolation.selector);
        sPinto.deposit(assets, user);

        // deposit advanced
        vm.expectPartialRevert(ISiloedPinto.MinPdvViolation.selector);
        sPinto.depositAdvanced(assets, user, From.EXTERNAL, To.EXTERNAL);

        // mint
        vm.expectPartialRevert(ISiloedPinto.MinPdvViolation.selector);
        sPinto.mint(assets, user);

        // mint advanced
        vm.expectPartialRevert(ISiloedPinto.MinPdvViolation.selector);
        sPinto.mintAdvanced(assets, user, From.EXTERNAL, To.EXTERNAL);
    }

    ///////////////// StemsAmountMismatch /////////////////

    function test_RevertStemsAmountMismatch() public useActor(0) {
        // deposit and mint sPinto using the silo deposits
        int96[] memory stems = new int96[](2);
        stems[0] = 1;
        stems[1] = 2;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1;
        vm.expectPartialRevert(ISiloedPinto.StemsAmountMismatch.selector);
        sPinto.depositFromSilo(stems, amounts, receiver, To.EXTERNAL);
    }

    ///////////////////// Simple Allowance Tests //////////////////////////

    ////////////////// Revert if owner!=msg.sender and no allowance //////////////////

    function test_RevertIfNoAllowance() public useActor(0) {
        uint256 assets = 1000e6;
        address attacker = makeAddr("attacker");
        // deposit and mint sPinto to receiver external balance
        sPinto.depositAdvanced(assets, receiver, From.EXTERNAL, To.EXTERNAL);
        // try to redeem from reciever to attacker without allowance
        vm.expectPartialRevert(ISiloedPinto.ERC20InsufficientAllowance.selector);
        sPinto.redeem(1e18, attacker, receiver);

        // // try to withdraw from receiver without allowance
        vm.expectPartialRevert(ISiloedPinto.ERC20InsufficientAllowance.selector);
        sPinto.withdraw(assets, attacker, receiver);
    }

    ////////////////// Allowance Spent //////////////////

    function test_AllowanceSpentRedeem() public useActor(0) {
        uint256 assets = 1000e6;
        uint256 shares = sPinto.convertToShares(assets);
        depositAndApprove(assets, receiver, user);
        // redeem from reciever to bob
        vm.prank(user);
        sPinto.redeem(shares, user, receiver);
        // verify that the allowance has been spent
        assertEq(sPinto.allowance(receiver, user), 0);
    }

    function test_AllowanceSpentWithdraw() public useActor(0) {
        uint256 assets = 1000e6;
        depositAndApprove(assets, receiver, user);
        vm.prank(user);
        sPinto.withdraw(assets, user, receiver);
        // verify that the allowance has been spent
        assertEq(sPinto.allowance(receiver, user), 0);
    }

    function test_AllowanceSpentWithdrawToSilo() public useActor(0) {
        uint256 assets = 1000e6;
        depositAndApprove(assets, receiver, user);
        // withdraw to silo from reciever to user
        vm.prank(user);
        sPinto.withdrawToSilo(assets, user, receiver, From.EXTERNAL);
        // verify that the allowance has been spent
        assertEq(sPinto.allowance(receiver, user), 0);
    }

    function test_AllowanceSpentRedeemToSilo() public useActor(0) {
        uint256 assets = 1000e6;
        uint256 shares = sPinto.convertToShares(assets);
        depositAndApprove(assets, receiver, user);
        // redeem to silo from reciever to user
        vm.prank(user);
        sPinto.redeemToSilo(shares, user, receiver, From.EXTERNAL);
        // verify that the allowance has been spent
        assertEq(sPinto.allowance(receiver, user), 0);
    }

    ////////////////// InvalidMode ///////////////////

    function test_RevertInvalidFromMode() public useActor(0) {
        uint256 assets = 1000e6;
        // try to deposit with invalid from mode
        vm.expectPartialRevert(ISiloedPinto.InvalidMode.selector);
        sPinto.depositAdvanced(assets, user, From.EXTERNAL_INTERNAL, To.EXTERNAL);

        // try to mint with invalid mode
        vm.expectPartialRevert(ISiloedPinto.InvalidMode.selector);
        sPinto.mintAdvanced(assets, user, From.INTERNAL_TOLERANT, To.EXTERNAL);

        // try to redeem with invalid from mode
        vm.expectPartialRevert(ISiloedPinto.InvalidMode.selector);
        sPinto.redeemAdvanced(assets, user, user, From.INTERNAL_TOLERANT, To.EXTERNAL);

        // try to withdraw with invalid from mode
        vm.expectPartialRevert(ISiloedPinto.InvalidMode.selector);
        sPinto.withdrawAdvanced(assets, user, user, From.EXTERNAL_INTERNAL, To.EXTERNAL);

        // getMaxRedeem with invalid from mode
        vm.expectPartialRevert(ISiloedPinto.InvalidMode.selector);
        sPinto.getMaxRedeem(user, From.INTERNAL_TOLERANT);

        // getMaxWithdraw with invalid from mode
        vm.expectPartialRevert(ISiloedPinto.InvalidMode.selector);
        sPinto.getMaxWithdraw(user, From.INTERNAL_TOLERANT);
    }

    /////////////////// Getters ///////////////////

    function test_properties() public view {
        assertEq(sPinto.decimals(), 18);
        uint256 pdvPerToken = sPinto.previewRedeem(1e18);
        assertEq(pdvPerToken, 1e6); // pdv/token hasn't increased yet
        assertEq(sPinto.name(), "Siloed Pinto");
        assertEq(sPinto.symbol(), "sPINTO");
        assertEq(sPinto.maxDeposit(address(1)), type(uint256).max);
        assertEq(sPinto.maxMint(address(1)), type(uint256).max);
        // owner
        assertEq(sPinto.owner(), address(PCM));
        // configuration
        uint256 maxTriggerPrice = 1.01e6;
        uint256 slippageRatio = 0.01e18; // 1%
        uint256 floodTranchRatio = 0.1e18; // 10%
        uint256 vestingPeriod = 4 hours;
        uint256 minSize = 1e6; // 1 PINTO
        uint256 targetMinSize = 10_000e6; // 10,000 PINTO
        assertEq(sPinto.maxTriggerPrice(), maxTriggerPrice);
        assertEq(sPinto.slippageRatio(), slippageRatio);
        assertEq(sPinto.floodTranchRatio(), floodTranchRatio);
        assertEq(sPinto.vestingPeriod(), vestingPeriod);
        assertEq(sPinto.minSize(), minSize);
        assertEq(sPinto.targetMinSize(), targetMinSize);
    }

    /////////////////// getMaxWithdraw, getMaxRedeem from INTERNAL ///////////////////

    function test_getMaxWithdrawInternal() public useActor(0) {
        uint256 assets = 1000e6;
        depositAndCheckAdvanced(assets, From.EXTERNAL, To.INTERNAL);
        uint256 maxWithdraw = sPinto.getMaxWithdraw(user, From.INTERNAL);
        assertEq(maxWithdraw, assets);
    }

    function test_getMaxRedeemInternal() public useActor(0) {
        uint256 assets = 1000e6;
        uint256 expectedShares = sPinto.convertToShares(assets);
        depositAndCheckAdvanced(assets, From.EXTERNAL, To.INTERNAL);
        uint256 maxRedeem = sPinto.getMaxRedeem(user, From.INTERNAL);
        assertEq(maxRedeem, expectedShares);
    }

    ///////////////// Rescue Tokens ///////////////////

    function test_RescueTokens() public {
        address weth = address(floodTokens[0]);
        deal(weth, address(sPinto), 1e18);
        assertEq(IERC20(weth).balanceOf(address(sPinto)), 1e18);

        // attempt to rescue tokens by a non owner, expect revert
        vm.prank(receiver);
        vm.expectRevert();
        sPinto.rescueTokens(weth, 1e18, receiver);
        vm.stopPrank();

        // rescue tokens by the owner
        vm.startPrank(PCM);
        // successful rescue
        sPinto.rescueTokens(weth, 1e18, PCM);
        // assert that tokens were transferred to the PCM
        assertEq(IERC20(weth).balanceOf(address(sPinto)), 0);
        assertEq(IERC20(weth).balanceOf(PCM), 1e18);
        vm.stopPrank();
    }

    ///////////////// Germinatiing Deposit List operations ///////////////////

    /**
     * @notice Tests moving 1 germinating deposit from germinating deposits list to regular deposits list
     * after the germination period has passed
     */
    function test_germinatingDepositsMoveOneDeposit() public {
        // single deposit
        uint256 assets = 1000e6;
        sPinto.deposit(assets, address(this));

        // asert that the length of germinating deposits is 1
        assertEq(sPinto.getGerminatingDepositsLength(), 1);
        // assert that one deposit is present with the correct amount
        (int96 stem, uint256 amount) = sPinto.germinatingDeposits(0);
        assertEq(amount, assets);
        // assert that the length of all deposits is 1 (only the germinating deposit)
        assertEq(sPinto.getDepositsLength(), 1);

        // pass germination for all
        proceedAndGm();
        proceedAndGm();

        // claim and move germinating deposits to regular deposits list
        sPinto.claim();

        // assert that the length of germinating deposits is 0
        assertEq(sPinto.getGerminatingDepositsLength(), 0);
        // assert that the length of regular deposits is 1
        assertEq(sPinto.getDepositsLength(), 1);
        // assert that one deposit is present with the correct amount
        (stem, amount) = sPinto.deposits(0);
        assertEq(amount, assets);
        checkDepositsAreOrdered();
    }

    /**
     * @notice Tests moving 2 germinating deposit from germinating deposits list to regular deposits list
     * after the germination period has passed and merging them in the process
     */
    function test_germinatingDepositsMoveMultipleDepositsMerge() public {
        // deposit 1
        uint256 assets = 1000e6;
        sPinto.deposit(assets, address(this));

        // change stems
        proceedAndGm();

        // deposit 2
        sPinto.deposit(assets, address(this));

        // asert that the length of germinating deposits is 2
        assertEq(sPinto.getGerminatingDepositsLength(), 2);
        // assert that one deposit is present with the correct amount
        (int96 stem, uint256 amount) = sPinto.germinatingDeposits(0);
        assertEq(amount, assets);
        // assert that the length of all deposits is 2 (only the germinating deposits)
        assertEq(sPinto.getDepositsLength(), 2);

        // pass germination for all
        proceedAndGm();
        proceedAndGm();

        // claim and move germinating deposits to regular deposits list
        // due to l2l coverts, they will be merged
        sPinto.claim();

        // assert that the length of germinating deposits is 0
        assertEq(sPinto.getGerminatingDepositsLength(), 0);
        // assert that the length of regular deposits is 1, the merged deposit
        assertEq(sPinto.getDepositsLength(), 1);
        (stem, amount) = sPinto.deposits(0);
        // assert that one deposit is present with the correct amount
        assertEq(amount, 2 * assets);
        checkDepositsAreOrdered();
    }

    /////////////////// Helpers ///////////////////

    /// @notice public variant of _pushDeposit in SiloedPinto
    function mockPushDeposit(int96 stem) public {
        // Empty array, just push the stem
        if (mockDeposits.length == 0) {
            mockDeposits.push(stem);
            return;
        }

        // If this deposit stem already exists, (stem == lastStem) do nothing
        if (stem == mockDeposits[mockDeposits.length - 1]) return;

        // If the array has elements and the new stem is greater than the last element, just push
        if (stem > mockDeposits[mockDeposits.length - 1]) {
            mockDeposits.push(stem);
            return;
        }

        // If the stem is less than the last element, insert it in the correct order by shifting backwards
        mockDeposits.push(0); // Increase the array size by one
        uint256 i = mockDeposits.length - 1; // Set the starting index to the length before the push
        // Shift elements backwards until the correct position is found
        while (i > 0 && mockDeposits[i - 1] > stem) {
            mockDeposits[i] = mockDeposits[i - 1];
            i--;
        }
        // Insert the stem into the correct position
        mockDeposits[i] = stem;
    }

    function depositAndApprove(uint256 amount, address owner, address spender) public {
        uint256 shares = sPinto.deposit(amount, owner);
        vm.prank(owner);
        sPinto.approve(spender, shares);
        // verify that the allowance has been set
        assertEq(sPinto.allowance(owner, spender), shares);
    }
}
