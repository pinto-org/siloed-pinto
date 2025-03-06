/**
 * SPDX-License-Identifier: MIT
 **/

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPintoProtocolExtended, From, To, Implementation} from "test/interfaces/IPintoProtocolExtended.sol";
import {IWell} from "test/interfaces/IWell.sol";
import {Call} from "src/interfaces/IWell.sol";
import {IMultiFlowPump} from "src/interfaces/IMultiFlowPump.sol";
import {ISiloedPinto} from "src/interfaces/ISiloedPinto.sol";
import {SiloedPinto} from "src/SiloedPinto.sol";
import {IPintoProtocol} from "src/interfaces/IPintoProtocol.sol";
import {IWellFunction} from "src/interfaces/IWellFunction.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "openzeppelin-foundry-upgrades/Upgrades.sol";
import "forge-std/console.sol";
import {AbstractSiloedPinto} from "src/AbstractSiloedPinto.sol";

contract TestHelpers is Test {
    uint256 BASE_BLOCK_NUM_DELTA_P_NEGATIVE = 24986024; // negative deltaP
    uint256 BASE_BLOCK_NUM_DELTA_P_POSITIVE = 25166527; // +20,974 TWAΔP
    // fork 2 seasons pre flood to get rain roots for deposits
    uint256 BASE_BLOCK_NUM_PRE_FLOOD = 22932726;
    address constant PCM = 0x2cf82605402912C6a79078a9BBfcCf061CbfD507;

    address PINTO = address(0xb170000aeeFa790fa61D6e837d1035906839a3c8);
    address PINTO_PROTOCOL = address(0xD1A0D188E861ed9d15773a2F3574a2e94134bA8f);
    address PINTO_PROTOCOL_OWNER = address(0x2cf82605402912C6a79078a9BBfcCf061CbfD507);
    address INIT_OWNER = PCM;
    address ZERO_ADDRESS = 0x0000000000000000000000000000000000000000;
    address DEALER = address(420);
    address BIN = address(1);

    // Note: These are moved to state so change if needed.
    uint256 MIN_SIZE = 1e6;
    uint256 MAX_PINTO = type(uint48).max;
    uint256 MAX_SPINTO = 100_000_000e18;
    uint256 TOTAL_VESTING_MINUTES = 240;

    // flood
    uint256 constant FLOOD_TRANCH_RATIO = 0.1e18; // 10%
    uint256 constant SLIPPAGE_RATIO = 0.01e18; // 1%
    uint256 constant MAX_TRIGGER_PRICE = 1.01e6;

    // forks
    uint256 negativeDeltaPFork;
    uint256 positiveDeltaPFork;
    uint256 preFloodFork;

    SiloedPinto sPinto;
    address sPintoProxy;
    IERC20 pinto = IERC20(PINTO);
    IPintoProtocolExtended pintoProtocol = IPintoProtocolExtended(PINTO_PROTOCOL);
    address[] public wells;
    IERC20[] public floodTokens;

    // mock deposit list for logic testing
    int96[] mockDeposits;

    address[] public actors;
    address user;
    address receiver = makeAddr("receiver");

    function createForks() public {
        // Create forks
        negativeDeltaPFork = vm.createFork("base", BASE_BLOCK_NUM_DELTA_P_NEGATIVE);
        positiveDeltaPFork = vm.createFork("base", BASE_BLOCK_NUM_DELTA_P_POSITIVE);
        preFloodFork = vm.createFork("base", BASE_BLOCK_NUM_PRE_FLOOD);
    }

    function _setUp() public {
        // set oracles to prevent timeout
        updateOracleTimeouts();

        // deploy transparent proxy with the initial implementation
        deploySiloedPinto();

        // create actors
        createActors();

        // create dealer and set wells
        createDealerAndSetWells();

        // deal Pinto to the testing contract and approve
        dealToTestContract();

        // label addresses
        labelAddresses();
    }

    function createDealerAndSetWells() public {
        // Initialize variables.
        wells = pintoProtocol.getWhitelistedWellLpTokens();

        // Set up an intermediary account for token dealing
        for (uint256 i = 0; i < wells.length; i++) {
            IWell well = IWell(wells[i]);
            IERC20 token = well.tokens()[1];
            floodTokens.push(token);
            vm.prank(DEALER);
            token.approve(address(well), type(uint256).max);
            vm.prank(DEALER);
            pinto.approve(address(well), type(uint256).max);
        }
    }

    function dealToTestContract() public {
        // Mint Pinto to the testing contract
        deal(address(PINTO), address(this), MAX_PINTO + 100e6);
        // approve WrappedPinto to spend Pinto on behalf of the testing contract
        IERC20(PINTO).approve(address(sPinto), type(uint256).max);
    }

    function deploySiloedPinto() public {
        // Flood Configuration.
        uint256 maxTriggerPrice = 1.01e6;
        uint256 slippageRatio = 0.01e18; // 1%
        uint256 floodTranchRatio = 0.1e18; // 10%
        uint256 vestingPeriod = 4 hours;
        uint256 minSize = 1e6;
        uint256 targetMinSize = 10_000e6;
        // deploy transparent proxy with the initial implementation
        sPintoProxy = Upgrades.deployTransparentProxy(
            "SiloedPinto.sol",
            INIT_OWNER, // initial owner, who can call the proxy admin
            abi.encodeCall(
                SiloedPinto.initialize,
                (
                    maxTriggerPrice,
                    slippageRatio,
                    floodTranchRatio,
                    vestingPeriod,
                    minSize,
                    targetMinSize
                )
            )
        );
        // Get the instance of the contract
        sPinto = SiloedPinto(sPintoProxy);
    }

    function createActors() public {
        // Mint Pinto to accounts to be used for testing
        actors.push(address(0xaccD909E5377978E739775B33F580F48E1Caf773));
        vm.label(address(0xaccD909E5377978E739775B33F580F48E1Caf773), "Actor 1");
        actors.push(address(0xae4BefD26511B6eC4f8A1d7B9E952A4062D9E5f6));
        vm.label(address(0xae4BefD26511B6eC4f8A1d7B9E952A4062D9E5f6), "Actor 2");
        for (uint256 i = 0; i < actors.length; i++) {
            deal(address(PINTO), actors[i], MAX_PINTO);
            vm.startPrank(actors[i]);
            pinto.approve(address(sPinto), type(uint256).max);
            pinto.approve(address(PINTO_PROTOCOL), type(uint256).max);
            pintoProtocol.approveToken(address(sPinto), IERC20(PINTO), type(uint256).max);
            pintoProtocol.approveToken(address(sPinto), IERC20(address(sPinto)), type(uint256).max);
            vm.stopPrank();
        }
    }

    function labelAddresses() public {
        vm.label(sPintoProxy, "sPinto");
        vm.label(PINTO, "PintoERC20");
        vm.label(PINTO_PROTOCOL, "Diamond");
        vm.label(DEALER, "token Dealer");
        vm.label(BIN, "BIN");
        vm.label(receiver, "Receiver");
    }

    modifier useActor(uint256 actorSeed) {
        _useActor(actorSeed);
        _;
    }

    function _useActor(uint256 actorSeed) public {
        actorSeed = bound(actorSeed, 0, actors.length - 1);
        user = actors[actorSeed];
    }

    function addActor(address addr) public {
        actors.push(addr);
    }

    // Running this many times with -vvv will cause memory overflow and kill the test.
    function proceedAndGm() public {
        vm.warp(block.timestamp + 60 * 60);
        vm.roll(block.number + (60 * 60) / 2);
        pintoProtocol.gm(BIN, To.EXTERNAL);
        // go forward to avoid no time passed error
        vm.warp(block.timestamp + 60);
        // mine 1 block to update the block number
        vm.roll(block.number + 30);
    }

    function skipVesting() public {
        vm.warp(block.timestamp + TOTAL_VESTING_MINUTES * 60);
    }

    modifier checkClaim() {
        uint256 earnedPintoMin = pintoProtocol.balanceOfEarnedBeans(address(sPinto));

        _;

        assertEq(pinto.balanceOf(address(sPinto)), 0, "checkClaim: ext");
        assertEq(pintoProtocol.getInternalBalance(address(sPinto), pinto), 0, "checkClaim: int");

        // Only plants if min size met.
        if (earnedPintoMin >= 1e6) {
            assertEq(pintoProtocol.balanceOfEarnedBeans(address(sPinto)), 0, "checkClaim: earned");
            assertGe(sPinto.unvestedAssets(), earnedPintoMin, "checkClaim: unvestedAssets");
        }
    }

    modifier checkWrap(uint256 assets, uint256 shares) {
        uint256 initialShares = sPinto.totalSupply();
        uint256 initialAssets = sPinto.totalAssets();
        uint256 initialBalShares = sPinto.balanceOf(user);
        uint256 initialBalAssets = pinto.balanceOf(user);

        _;

        assertEq(sPinto.totalSupply(), initialShares + shares, "checkWrap: total supply");
        assertEq(sPinto.totalAssets(), initialAssets + assets, "checkWrap: underlying pdv");
        assertEq(sPinto.balanceOf(user), initialBalShares + shares, "checkWrap: user balance");
        assertEq(pinto.balanceOf(user), initialBalAssets - assets, "checkWrap: balance");
    }

    modifier checkUnwrap(uint256 assets, uint256 shares) {
        uint256 initialShares = sPinto.totalSupply();
        uint256 initialAssets = sPinto.totalAssets();
        uint256 initialBalShares = sPinto.balanceOf(user);
        uint256 initialBalAssets = pinto.balanceOf(user);

        _;

        assertEq(sPinto.totalSupply(), initialShares - shares, "checkUnwrap: total supply");
        assertEq(sPinto.totalAssets(), initialAssets - assets, "checkUnwrap: underlying pdv");
        assertEq(sPinto.balanceOf(user), initialBalShares - shares, "checkUnwrap: user balance");
        assertEq(pinto.balanceOf(user), initialBalAssets + assets, "checkUnwrap: balance");
    }

    function dealSPinto(address recipient, uint256 shares) internal {
        uint256 assets = sPinto.previewDeposit(shares);
        deal(address(PINTO), DEALER, assets);
        vm.prank(DEALER);
        pinto.approve(address(sPinto), assets);
        vm.prank(DEALER);
        sPinto.deposit(assets, recipient);
    }

    /// @notice Deals tokens so that new assets are added to the well reserves.
    function setLiquidityInWell(
        address account,
        address well,
        uint256 pintoAmount,
        uint256 nonPintoTokenAmount
    ) internal returns (uint256 lpOut) {
        (address nonBeanToken, ) = pintoProtocol.getNonBeanTokenAndIndexFromWell(well);
        deal(address(PINTO), well, pintoAmount, false);
        deal(address(nonBeanToken), well, nonPintoTokenAmount, false);
        lpOut = IWell(well).sync(account, 0);
        // sync again to update reserves.
        IWell(well).sync(account, 0);
    }

    /// @notice Deals tokens so that new assets are added to the well reserves.
    function setLiquidityInWellNoSync(
        address well,
        uint256 pintoAmount,
        uint256 nonPintoTokenAmount
    ) internal {
        (address nonBeanToken, ) = pintoProtocol.getNonBeanTokenAndIndexFromWell(well);
        deal(address(PINTO), well, pintoAmount, false);
        deal(address(nonBeanToken), well, nonPintoTokenAmount, false);
    }

    function addSmallFloodLiquidityToAllWellsNoSync() public {
        uint256 pintoAmount = 1000000e6;
        uint256[] memory nonPintoTokenAmounts = new uint256[](wells.length);
        nonPintoTokenAmounts[0] = 1500e18; // weth
        nonPintoTokenAmounts[1] = 1500e18; // cbeth
        nonPintoTokenAmounts[2] = 1100e8; // cbbtc
        nonPintoTokenAmounts[3] = 60000000e6; // usdc
        nonPintoTokenAmounts[4] = 1000000e9; // wsol
        for (uint256 i = 0; i < wells.length; i++) {
            setLiquidityInWellNoSync(wells[i], pintoAmount, nonPintoTokenAmounts[i]);
        }
    }

    function addFloodLiquidityToAllWells(address account) public {
        uint256 pintoAmount = 1000e6;
        uint256[] memory nonPintoTokenAmounts = new uint256[](wells.length);
        nonPintoTokenAmounts[0] = 10000e18; // weth
        nonPintoTokenAmounts[1] = 10000e18; // cbeth
        nonPintoTokenAmounts[2] = 1000e8; // cbbtc
        nonPintoTokenAmounts[3] = 10000000e6; // usdc
        nonPintoTokenAmounts[4] = 100000e9; // wsol
        for (uint256 i = 0; i < wells.length; i++) {
            setLiquidityInWell(account, wells[i], pintoAmount, nonPintoTokenAmounts[i]);
        }
    }

    function addSmallFloodLiquidityToAllWells(address account) public {
        uint256 pintoAmount = 1000000e6;
        uint256[] memory nonPintoTokenAmounts = new uint256[](wells.length);
        nonPintoTokenAmounts[0] = 1500e18; // weth
        nonPintoTokenAmounts[1] = 1500e18; // cbeth
        nonPintoTokenAmounts[2] = 1100e8; // cbbtc
        nonPintoTokenAmounts[3] = 60000000e6; // usdc
        nonPintoTokenAmounts[4] = 1000000e9; // wsol
        for (uint256 i = 0; i < wells.length; i++) {
            setLiquidityInWell(account, wells[i], pintoAmount, nonPintoTokenAmounts[i]);
        }
    }

    function addInvalidPriceLiquidityToAllWells(address account) public {
        uint256 pintoAmount = 1000000000e6;
        uint256[] memory nonPintoTokenAmounts = new uint256[](wells.length);
        nonPintoTokenAmounts[0] = 1500000e18; // weth
        nonPintoTokenAmounts[1] = 2300000e18; // cbeth
        nonPintoTokenAmounts[2] = 110000e8; // cbbtc
        nonPintoTokenAmounts[3] = 6000000000e6; // usdc
        nonPintoTokenAmounts[4] = 10000000e9; // wsol
        for (uint256 i = 0; i < wells.length; i++) {
            setLiquidityInWell(account, wells[i], pintoAmount, nonPintoTokenAmounts[i]);
        }
    }

    function addAntiFloodLiquidityToAllWells(address account) public {
        uint256 pintoAmount = 100000000e6;
        uint256[] memory nonPintoTokenAmounts = new uint256[](wells.length);
        nonPintoTokenAmounts[0] = 10000e18; // weth
        nonPintoTokenAmounts[1] = 10000e18; // cbeth
        nonPintoTokenAmounts[2] = 1000e8; // cbbtc
        nonPintoTokenAmounts[3] = 10000000e6; // usdc
        nonPintoTokenAmounts[4] = 10000e9; // wsol
        for (uint256 i = 0; i < wells.length; i++) {
            setLiquidityInWell(account, wells[i], pintoAmount, nonPintoTokenAmounts[i]);
        }
    }

    /// @dev amounts are very high to avoid overflow when calculating pdv of flood balance
    /// @dev amounts correspond to a low deltab so that swap sends it close to 0 without a lot of slippage
    function addAntiFloodLiquidityToUsdcWell(address account) public {
        uint256 pintoAmount = 100_000_000e6;
        uint256[] memory nonPintoTokenAmounts = new uint256[](wells.length);
        nonPintoTokenAmounts[3] = 99_999_000e6; // usdc
        setLiquidityInWell(account, wells[3], pintoAmount, nonPintoTokenAmounts[3]);
    }

    function addSmallAntiFloodLiquidityToAllWells(address account) public {
        uint256 pintoAmount = 100e6;
        uint256[] memory nonPintoTokenAmounts = new uint256[](wells.length);
        nonPintoTokenAmounts[0] = 0.001e18; // weth
        nonPintoTokenAmounts[1] = 0.001e18; // cbeth
        nonPintoTokenAmounts[2] = 0.000001e8; // cbbtc
        nonPintoTokenAmounts[3] = 0.001e6; // usdc
        nonPintoTokenAmounts[4] = 0.001e9; // wsol
        for (uint256 i = 0; i < wells.length; i++) {
            setLiquidityInWell(account, wells[i], pintoAmount, nonPintoTokenAmounts[i]);
        }
    }

    function addInvalidPriceLiquidityToSomeWells(address account) public {
        uint256 pintoAmount = 1000000e6;
        uint256[] memory nonPintoTokenAmounts = new uint256[](wells.length);
        nonPintoTokenAmounts[0] = 10000e18; // weth
        nonPintoTokenAmounts[1] = 150e18; // cbeth
        nonPintoTokenAmounts[2] = 10e8; // cbbtc
        nonPintoTokenAmounts[3] = 10000000e6; // usdc
        nonPintoTokenAmounts[4] = 10000e9; // wsol
        for (uint256 i = 0; i < wells.length; i++) {
            setLiquidityInWell(account, wells[i], pintoAmount, nonPintoTokenAmounts[i]);
        }
    }

    /**
     * @notice Sets the deltaP of the protocol based on given magnitude.
     * @dev Not guaranteed to be exact or match sign of magnitude.
     * @param magnitude The magnitude of the deltaP to set. A ratio from -1e18 to 1e18.
     */
    function setDeltaPApproximate(int256 magnitude) internal {
        console.log("magnitude: %d", magnitude);

        // Behavior falls apart at the margins. Values are very approximate.
        if (magnitude < -0.8e18) {
            magnitude = -0.8e18;
        }
        if (magnitude > 0.8e18) {
            magnitude = 0.8e18;
        }
        if (magnitude > -1e17 && magnitude < 0) {
            magnitude = -1e17;
        } else if (magnitude > 0 && magnitude < 1e17) {
            magnitude = 1e17;
        }

        uint256[] memory nonPintoTokenAmounts = new uint256[](wells.length);
        nonPintoTokenAmounts[0] = 45e18; // weth
        nonPintoTokenAmounts[1] = 45e18; // cbeth
        nonPintoTokenAmounts[2] = 1e8; // cbbtc
        nonPintoTokenAmounts[3] = 100_000e6; // usdc
        nonPintoTokenAmounts[4] = 400e9; // wsol

        uint256 pintoAmount = 500_000e6 / wells.length;
        if (magnitude > 0) {
            pintoAmount = uint256((int256(pintoAmount) * (1e18 - magnitude)) / 1e18);
        } else {
            pintoAmount = uint256((int256(pintoAmount) * (1e18 - magnitude)) / 1e18);
        }
        for (uint256 i = 0; i < wells.length; i++) {
            setLiquidityInWell(user, wells[i], pintoAmount, nonPintoTokenAmounts[i]);
        }
    }

    function claimAndCheck() internal checkClaim {
        uint256 initialAssets = sPinto.totalAssets();

        sPinto.claim();

        // All new assets vesting, no change to total assets.
        assertEq(sPinto.totalAssets(), initialAssets, "checkClaim: vesting");
    }

    function depositAndCheck(
        uint256 assets
    ) internal checkClaim checkWrap(assets, sPinto.previewDeposit(assets)) {
        uint256 expectedShares = sPinto.convertToShares(assets);

        // Expect deposit event
        vm.expectEmit();
        emit ISiloedPinto.Deposit(user, user, assets, expectedShares);
        // Deposit
        vm.prank(user);
        uint256 sharesOut = sPinto.deposit(assets, user);

        assertEq(sharesOut, expectedShares, "depositAndCheck: shares out");
        checkDepositsAreOrdered();
    }

    /// @notice Deposit Pinto to the silo and step the season to update stems
    function depositToSilo(uint256 pintoAmount) public returns (uint256, uint256, int96) {
        // approve the diamond to pull Pinto from the caller
        pinto.approve(PINTO_PROTOCOL, pintoAmount);
        proceedAndGm();
        // deposit Pinto into the silo
        (uint256 amount, uint256 _bdv, int96 stem) = pintoProtocol.deposit(
            PINTO,
            pintoAmount,
            From.EXTERNAL
        );
        return (amount, _bdv, stem);
    }

    function depositAndCheckAdvanced(uint256 assets, From fromMode, To toMode) internal {
        uint256 expectedShares = sPinto.convertToShares(assets);

        // Expect deposit event
        vm.expectEmit();
        emit ISiloedPinto.Deposit(user, user, assets, expectedShares);
        // Deposit
        vm.prank(user);
        uint256 sharesOut = sPinto.depositAdvanced(assets, user, fromMode, toMode);

        assertEq(sharesOut, expectedShares, "depositAndCheckAdvanced: shares out");
        checkDepositsAreOrdered();
    }

    function mintAndCheck(
        uint256 shares
    ) internal checkClaim checkWrap(sPinto.previewMint(shares), shares) {
        uint256 expectedAssets = sPinto.previewMint(shares);
        uint256 earnedPintoMin = pintoProtocol.balanceOfEarnedBeans(address(sPinto));
        earnedPintoMin = earnedPintoMin < 1e6 ? 0 : earnedPintoMin;

        // Expect mint event
        vm.expectEmit();
        emit ISiloedPinto.Deposit(user, user, expectedAssets, shares);
        // Mint
        vm.prank(user);
        uint256 assetsOut = sPinto.mint(shares, user);

        assertEq(assetsOut, expectedAssets, "mintAndCheck: assets out");
        // A deposit exists at current stem with all earned pinto (and possibly existing pinto).
        int96 earnedStem = pintoProtocol.getGerminatingStem(PINTO) - 1;
        (uint256 amount, ) = pintoProtocol.getDeposit(address(sPinto), PINTO, earnedStem);
        assertGe(amount, earnedPintoMin, "mintAndCheck: deposit amount");
        assertEq(assetsOut, expectedAssets, "mintAndCheck: assets out");
        checkDepositsAreOrdered();
    }

    function mintAndCheckAdvanced(uint256 shares, From fromMode, To toMode) internal {
        uint256 expectedAssets = sPinto.previewMint(shares);

        // Expect mint event
        vm.expectEmit();
        emit ISiloedPinto.Deposit(user, user, expectedAssets, shares);
        // Mint
        vm.prank(user);
        uint256 assetsOut = sPinto.mintAdvanced(shares, user, fromMode, toMode);

        assertEq(assetsOut, expectedAssets, "mintAndCheckAdvanced: assets out");
        checkDepositsAreOrdered();
    }

    function withdrawAndCheck(
        uint256 assets
    ) internal checkClaim checkUnwrap(assets, sPinto.previewWithdraw(assets)) {
        uint256 expectedShares = sPinto.previewWithdraw(assets);

        // Expect withdraw event
        emit ISiloedPinto.Withdraw(address(this), user, user, assets, expectedShares);
        // Withdraw
        vm.prank(user);
        uint256 sharesOut = sPinto.withdraw(assets, user, user);

        assertEq(sharesOut, expectedShares, "withdrawAndCheck: shares out");
    }

    function withdrawAndCheckAdvanced(uint256 assets, From fromMode, To toMode) internal {
        uint256 expectedShares = sPinto.previewWithdraw(assets);

        // Expect withdraw event
        emit ISiloedPinto.Withdraw(address(this), user, user, assets, expectedShares);
        // Withdraw
        vm.prank(user);
        uint256 sharesOut = sPinto.withdrawAdvanced(assets, user, user, fromMode, toMode);

        assertEq(sharesOut, expectedShares, "withdrawAndCheckAdvanced: shares out");
    }

    function redeemAndCheck(
        uint256 shares
    ) internal checkClaim checkUnwrap(sPinto.previewRedeem(shares), shares) {
        uint256 expectedAssets = sPinto.previewRedeem(shares);

        // Expect redeem event
        emit ISiloedPinto.Withdraw(user, user, user, expectedAssets, shares);
        // Redeem
        vm.prank(user);
        uint256 assetsOut = sPinto.redeem(shares, user, user);

        assertEq(assetsOut, expectedAssets, "redeemAndCheck: assets out");
    }

    function redeemAndCheckAdvanced(uint256 shares, From fromMode, To toMode) internal {
        uint256 expectedAssets = sPinto.previewRedeem(shares);

        // Expect redeem event
        emit ISiloedPinto.Withdraw(user, user, user, expectedAssets, shares);
        // Redeem
        vm.prank(user);
        uint256 assetsOut = sPinto.redeemAdvanced(shares, user, user, fromMode, toMode);

        assertEq(assetsOut, expectedAssets, "redeemAndCheckAdvanced: assets out");
    }

    // @notice Check the internal and external balances of sPinto of the receiver
    function checkBalances(
        uint256 expectedPintoInternalBalance,
        uint256 expectedPintoExternalBalance,
        uint256 expectedSPintoInternalBalance,
        uint256 expectedSPintoExternalBalance,
        address account
    ) public view {
        // get internal balance of account
        uint256 accountSpintoInternalBalance = pintoProtocol.getInternalBalance(
            account,
            IERC20(address(sPinto))
        );
        uint256 accountPintoInternalBalance = pintoProtocol.getInternalBalance(
            account,
            IERC20(PINTO)
        );
        // check that the account pinto internal balance is correct
        assertEq(
            accountPintoInternalBalance,
            expectedPintoInternalBalance,
            "checkBalances: Invalid Pinto internal balance"
        );
        // check that the account spinto internal balance is correct
        assertEq(
            accountSpintoInternalBalance,
            expectedSPintoInternalBalance,
            "checkBalances: Invalid sPinto internal balance"
        );
        // check that the account sPinto external balance is correct
        assertEq(
            sPinto.balanceOf(account),
            expectedSPintoExternalBalance,
            "checkBalances: Invalid sPinto external balance"
        );
        // check that the account pinto external balance is correct
        assertEq(
            pinto.balanceOf(account),
            expectedPintoExternalBalance,
            "checkBalances: Invalid Pinto external balance"
        );
    }

    /// @notice Check the vesting of earned Pinto in intervals of intervalMins up to 2 hours
    function checkVestingInIntervals(
        uint256 initialAssets,
        uint256 earnedPinto,
        uint256 intervalMins,
        bool verbose
    ) public {
        // All new assets vesting, no change to total assets.
        assertEq(sPinto.totalAssets(), initialAssets, "not all vesting");

        // Calculate how many intervals fit into 120 minutes.
        uint256 steps = TOTAL_VESTING_MINUTES / intervalMins;
        uint256 startTime = block.timestamp;

        for (uint256 i = 1; i <= steps; i++) {
            vm.warp(block.timestamp + (intervalMins * 1 minutes));

            // Figure out how many minutes have elapsed since we began vesting.
            uint256 elapsed = block.timestamp - startTime; // in seconds
            uint256 fractionNumerator = elapsed / 60; // elapsed in minutes
            uint256 expectedPartial = initialAssets +
                (earnedPinto * fractionNumerator) /
                TOTAL_VESTING_MINUTES;

            // If this is the final iteration we expect full vesting
            if (i == steps) {
                // Full vesting after 2 hours
                if (verbose) {
                    console.log(
                        "Checking final vesting at iteration %s (elapsed %s minutes)",
                        i,
                        fractionNumerator
                    );
                }
                assertEq(
                    sPinto.totalAssets(),
                    initialAssets + earnedPinto,
                    "invalid fully vested after 2 hrs"
                );
            } else {
                // Partial vesting
                if (verbose) {
                    console.log(
                        "Checking partial vesting at iteration %s (elapsed %s minutes)",
                        i,
                        fractionNumerator
                    );
                }
                assertApproxEqAbs(
                    sPinto.totalAssets(),
                    expectedPartial,
                    2, // tolerance
                    "invalid partial vesting"
                );
            }
        }
    }

    function checkDepositsAreOrdered() public view {
        uint256 expectedTotal = sPinto.totalAssets() + sPinto.unvestedAssets();

        // Get lengths of the combined list and the germinating deposits.
        uint256 combinedCount = sPinto.getDepositsLength();
        uint256 germinatingCount = sPinto.getGerminatingDepositsLength();
        // Regular deposits are those not in the germinating list.
        uint256 normalCount = combinedCount - germinatingCount;

        // log all regular deposits
        console.log("\n------------- Check Regular --------------------");
        for (uint256 i = 0; i < sPinto.getDepositsLength(); i++) {
            AbstractSiloedPinto.SiloDeposit memory tdeposit = sPinto.getDeposit(i);
            console.log("Stem %d:", i);
            console.logInt(tdeposit.stem);
            console.log("Deposit %d: %d", i, tdeposit.amount);
        }

        uint256 totalNormal = 0;
        if (normalCount > 0) {
            // Check ordering for regular deposits.
            (int96 prevStem, uint160 prevAmount) = sPinto.deposits(0);
            totalNormal += prevAmount;
            for (uint256 i = 1; i < normalCount; i++) {
                (int96 currStem, uint160 currAmount) = sPinto.deposits(i);
                assertLt(
                    prevStem,
                    currStem,
                    "checkDepositsAreOrdered: regular deposits not strictly ordered by stem"
                );
                totalNormal += currAmount;
                prevStem = currStem;
            }
        }

        // log all germinating deposits
        console.log("\n------------- Check Germinating --------------------");
        for (uint256 i = 0; i < sPinto.getGerminatingDepositsLength(); i++) {
            (int96 currGermStem, uint256 currGermAmount) = sPinto.germinatingDeposits(i);
            console.log("Stem %d:", i);
            console.logInt(currGermStem);
            console.log("Deposit %d: %d", i, currGermAmount);
        }
        console.log("\n------------- End Check Germinating --------------------");

        uint256 totalGerminating = 0;
        if (germinatingCount > 0) {
            // Check ordering for germinating deposits.
            (int96 prevGermStem, uint256 prevGermAmount) = sPinto.germinatingDeposits(0);
            totalGerminating += prevGermAmount;
            for (uint256 j = 1; j < germinatingCount; j++) {
                (int96 currGermStem, uint256 currGermAmount) = sPinto.germinatingDeposits(j);
                assertLt(
                    prevGermStem,
                    currGermStem,
                    "checkDepositsAreOrdered: germinating deposits not strictly ordered by stem"
                );
                totalGerminating += currGermAmount;
                prevGermStem = currGermStem;
                prevGermAmount = currGermAmount;
            }
        }

        uint256 totalAmount = totalNormal + totalGerminating;
        assertEq(
            totalAmount,
            expectedTotal,
            "checkDepositsAreOrdered: total deposit amount mismatch"
        );
    }

    ////////////////////////// Price Helpers //////////////////////////

    function isValidSlippage(
        IWell well,
        IERC20 token,
        uint256 slippageRatio
    ) internal view returns (bool) {
        IPintoProtocol protocol = IPintoProtocol(PINTO_PROTOCOL);
        Call memory pump = well.pumps()[0];
        Call memory wellFunction = IWell(well).wellFunction();
        (, uint256 nonBeanIndex) = protocol.getNonBeanTokenAndIndexFromWell(address(well));
        uint256 beanIndex = nonBeanIndex == 0 ? 1 : 0;

        // Capped reserves are the current reserves capped with the data from the pump.
        uint256[] memory currentReserves = IMultiFlowPump(pump.target).readCappedReserves(
            address(well),
            pump.data
        );
        uint256 currentPintoPerAsset = calculateTokenBeanPriceFromReserves(
            address(token),
            beanIndex,
            nonBeanIndex,
            currentReserves,
            wellFunction
        );
        if (currentPintoPerAsset == 0) return false;

        // InstantaneousReserves are exponential moving average (EMA).
        uint256[] memory instantReserves = IMultiFlowPump(pump.target).readInstantaneousReserves(
            address(well),
            pump.data
        );
        uint256 instantPintoPerAsset = calculateTokenBeanPriceFromReserves(
            address(token),
            beanIndex,
            nonBeanIndex,
            instantReserves,
            wellFunction
        );
        if (instantPintoPerAsset == 0) return false;

        // Current rate must be within slippage bounds relative to instantaneous rate.
        uint256 lowerLimit = instantPintoPerAsset - (slippageRatio * instantPintoPerAsset) / 1e18;
        uint256 upperLimit = instantPintoPerAsset + (slippageRatio * instantPintoPerAsset) / 1e18;
        if (currentPintoPerAsset < lowerLimit || currentPintoPerAsset > upperLimit) {
            return false;
        }
        return true;
    }

    function calculateTokenBeanPriceFromReserves(
        address nonBeanToken,
        uint256 beanIndex,
        uint256 nonBeanIndex,
        uint256[] memory reserves,
        Call memory wellFunction
    ) public view returns (uint256 price) {
        // attempt to calculate the LP token Supply.
        try
            IWellFunction(wellFunction.target).calcLpTokenSupply(reserves, wellFunction.data)
        returns (uint256 lpTokenSupply) {
            uint256 oldReserve = reserves[nonBeanIndex];
            reserves[beanIndex] = reserves[beanIndex] + 1e6; // 1e6 == 1 Pinto.

            try
                IWellFunction(wellFunction.target).calcReserve(
                    reserves,
                    nonBeanIndex,
                    lpTokenSupply,
                    wellFunction.data
                )
            returns (uint256 newReserve) {
                // Measure the delta of the non bean reserve.
                // Due to the invariant of the well function, old reserve > new reserve.
                uint256 delta = oldReserve - newReserve;
                price = (10 ** (IERC20Metadata(nonBeanToken).decimals() + 6)) / delta;
            } catch {
                return 0;
            }
        } catch {
            return 0;
        }
    }

    function isValidMaxPrice(
        IWell well,
        IERC20 token,
        uint256 maxPrice
    ) public view returns (bool) {
        IPintoProtocol protocol = IPintoProtocol(PINTO_PROTOCOL);
        uint256 assetPrice = protocol.getUsdTokenPrice(address(token)); // $1 gets assetPrice worth of tokens
        if (assetPrice == 0) {
            return false;
        }
        uint256 pintoPrice = (well.getSwapOut(IERC20(PINTO), token, 1e6) * 1e6) / assetPrice;
        if (pintoPrice > maxPrice) {
            return false;
        }
        return true;
    }

    ////////////////////////// Oracle Helpers //////////////////////////

    /// @notice Updates the oracle timeout for all whitelisted LP tokens to 365 days.
    function updateOracleTimeouts() public {
        vm.startPrank(PINTO_PROTOCOL_OWNER);
        address[] memory whitelistedWells = pintoProtocol.getWhitelistedWellLpTokens();
        for (uint256 i = 0; i < whitelistedWells.length; i++) {
            address wellAddress = whitelistedWells[i];
            IERC20[] memory wellTokens = IWell(wellAddress).tokens();
            // non pinto is the second token in the well
            address nonPintoToken = address(wellTokens[1]);
            // fetch the current oracle implementation for that non-Pinto token
            Implementation memory currentImpl = pintoProtocol.getOracleImplementationForToken(
                nonPintoToken
            );

            // Construct a new Implementation struct with the updated timeout data (365 days)
            Implementation memory newImpl = Implementation({
                target: currentImpl.target,
                selector: currentImpl.selector,
                encodeType: currentImpl.encodeType,
                data: abi.encodePacked(uint256(86400 * 365))
            });
            pintoProtocol.updateOracleImplementationForToken(nonPintoToken, newImpl);
        }
        vm.stopPrank();
    }
}
