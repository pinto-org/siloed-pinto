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
import {SiloDeposit} from "src/interfaces/ISiloedPinto.sol";
import {AbstractSiloedPinto} from "src/AbstractSiloedPinto.sol";
import "forge-std/console.sol";
import "openzeppelin-foundry-upgrades/Upgrades.sol";
import {TestHelpers} from "test/TestHelpers.sol";

contract SiloedPintoFromDepositsTest is TestHelpers {
    function setUp() public {
        createForks();
        // fork when deltaP is negative to exclude earned pinto logic
        vm.selectFork(negativeDeltaPFork);
        // set the environment in the current fork
        _setUp();
    }

    ////////////////////////// Deposit From Silo //////////////////////////

    function test_depositFromSilo() public {
        (uint256 amount, , int96 stem) = depositToSilo(100e6);
        (uint256 amount2, , int96 stem2) = depositToSilo(100e6);

        // approve deposits to be spend by sPinto
        pintoProtocol.approveDeposit(address(sPinto), PINTO, amount + amount2);

        // deposit and mint sPinto using the silo deposits
        int96[] memory stems = new int96[](2);
        stems[0] = stem;
        stems[1] = stem2;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amount;
        amounts[1] = amount2;

        // get the length of the deposits
        uint256 preLength = sPinto.getDepositsLength();

        uint256 expectedShares = sPinto.previewDeposit(amount + amount2);

        // Expect mint event
        vm.expectEmit();
        emit ISiloedPinto.Deposit(address(this), receiver, amount + amount2, expectedShares);

        uint256 shares = sPinto.depositFromSilo(stems, amounts, receiver, To.EXTERNAL);

        assertEq(shares, expectedShares);
        assertEq(sPinto.balanceOf(receiver), expectedShares);
        // check that the deposits were pushed into the deposits array
        assertEq(sPinto.getDepositsLength(), preLength + 2);
    }

    ////////////////////////// Deposit From Silo Special case //////////////////////////

    /**
     * @notice Tests the scenario where the incoming deposit is non germinating
     * and the previous deposit amount exceeds the target size,
     * and we can just push the deposit to the next index.
     *
     * Also tests the scenario where the incoming deposit is non germinating
     * and the previous deposit amount is below the target size, so the deposits get merged.
     */
    function test_depositFromSiloMergeDeposits() public {
        // first germinating deposit above the target size
        sPinto.deposit(100_000e6, receiver);
        // pass germination and move into the regular deposits list
        proceedAndGm();
        proceedAndGm();
        sPinto.claim();
        // deposit in the silo
        (uint256 amount, , int96 stem) = depositToSilo(100e6);
        // approve deposits to be spend by sPinto
        pintoProtocol.approveDeposit(address(sPinto), PINTO, amount);
        // pass germination in the silo
        proceedAndGm();
        proceedAndGm();

        // assert that the length of all deposits is 1 and no germianting deposits
        assertEq(sPinto.getDepositsLength(), 1);
        assertEq(sPinto.getGerminatingDepositsLength(), 0);

        // deposit and mint sPinto using the silo deposits
        int96[] memory stems = new int96[](1);
        stems[0] = stem;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        sPinto.depositFromSilo(stems, amounts, receiver, To.EXTERNAL);

        // assert that the new non-germinating deposit was added to the regular deposits list
        // and since the previous deposit is above the target size, it was pushed to the next index
        assertEq(sPinto.getDepositsLength(), 2);
        assertEq(sPinto.getGerminatingDepositsLength(), 0);

        // get deposits[1] and check that it is the new deposit
        (int96 _stem, uint160 _amount) = sPinto.deposits(1);
        assertEq(_stem, stem);
        assertEq(_amount, amount);

        ///////////////////////// Merge Deposits //////////////////////////

        // deposit again a non germinating deposit from silo and check
        // that it gets merged into the previous deposit

        // deposit in the silo
        (uint256 amount2, , int96 stem2) = depositToSilo(100e6);
        // approve deposits to be spend by sPinto
        pintoProtocol.approveDeposit(address(sPinto), PINTO, amount2);
        // pass germination in the silo
        proceedAndGm();
        proceedAndGm();

        // assert that the length of all deposits is 2 and no germianting deposits
        assertEq(sPinto.getDepositsLength(), 2);
        assertEq(sPinto.getGerminatingDepositsLength(), 0);

        // deposit and mint sPinto using the silo deposit
        int96[] memory stems2 = new int96[](1);
        stems2[0] = stem2;
        uint256[] memory amounts2 = new uint256[](1);
        amounts2[0] = amount2;
        sPinto.depositFromSilo(stems2, amounts2, receiver, To.EXTERNAL);

        // assert that the new non-germinating deposit was added to the regular deposits list
        // and since the previous deposit is below the target size, it was merged into the previous deposit
        assertEq(sPinto.getDepositsLength(), 2);
        assertEq(sPinto.getGerminatingDepositsLength(), 0);

        // get deposits[1] and check that it is the new deposit
        (, uint160 _amount2) = sPinto.deposits(1);
        assertEq(_amount2, amount + amount2);

        // check the order of the deposits
        checkDepositsAreOrdered();
    }

    /**
     * @notice Tests the scenario where the incoming silo deposit is germinating
     */
    function test_depositFromSiloGerminatingDeposit() public {
        // transfer a germinating deposit directly from silo to sPinto
        // check that the deposit is added to the germinating deposits list

        // deposit in the silo
        (uint256 amount, , int96 stem) = depositToSilo(100e6);
        // approve deposits to be spend by sPinto
        pintoProtocol.approveDeposit(address(sPinto), PINTO, amount);

        // deposit and mint sPinto using the silo deposits
        int96[] memory stems = new int96[](1);
        stems[0] = stem;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        sPinto.depositFromSilo(stems, amounts, receiver, To.EXTERNAL);

        // assert that the new germinating deposit was added to the germinating deposits list
        assertEq(sPinto.getDepositsLength(), 1);
        assertEq(sPinto.getGerminatingDepositsLength(), 1);

        // get germinating deposits[0] and check that it is the new deposit
        (int96 depositStem, uint256 depositAmount) = sPinto.germinatingDeposits(0);
        assertEq(depositStem, stem);
        assertEq(depositAmount, amount);
    }

    /////////////////////// Deposit From Silo Allowance //////////////////////////

    function test_RevertDepositFromSiloNoAllowance() public {
        (uint256 amount, , int96 stem) = depositToSilo(100e6);
        (uint256 amount2, , int96 stem2) = depositToSilo(100e6);

        // deposit and mint sPinto using the silo deposits
        int96[] memory stems = new int96[](2);
        stems[0] = stem;
        stems[1] = stem2;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amount;
        amounts[1] = amount2;

        // expect revert with no allowance
        vm.expectRevert("Silo: insufficient allowance");
        uint256 shares = sPinto.depositFromSilo(stems, amounts, receiver, To.EXTERNAL);

        // half allowance
        pintoProtocol.approveDeposit(address(sPinto), PINTO, amount);
        vm.expectRevert("Silo: insufficient allowance");
        shares = sPinto.depositFromSilo(stems, amounts, receiver, To.EXTERNAL);
    }

    /////////////////////// Deposit From Silo Not Found //////////////////////////

    function test_RevertDepositFromSiloDepositNotFound() public {
        (uint256 amount, , int96 stem) = depositToSilo(100e6);
        // deposit and mint sPinto using the silo deposits
        int96[] memory stems = new int96[](1);
        stems[0] = stem + 10; // random non existent stem
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        // approve
        pintoProtocol.approveDeposit(address(sPinto), PINTO, amount);
        // expect failure due to non existent deposit
        vm.expectRevert("Silo: Crate balance too low.");
        sPinto.depositFromSilo(stems, amounts, receiver, To.EXTERNAL);
    }

    ////////////////////////// Withdraw to Silo //////////////////////////

    function test_withdrawToSilo() public {
        uint256 assets = 100e6;
        // deposit and mint sPinto to receiver external balance
        uint256 shares1 = sPinto.depositAdvanced(assets, receiver, From.EXTERNAL, To.EXTERNAL);
        // call sunrise to get new stems
        proceedAndGm();
        uint256 shares2 = sPinto.depositAdvanced(assets, receiver, From.EXTERNAL, To.EXTERNAL);
        // deposit list [100 100]

        // get the length of the deposits pre withdraw
        // all fresh deposits are germianting deposits
        uint256 preLength = sPinto.getGerminatingDepositsLength();
        assertEq(preLength, 2);
        // get the stems of the deposits
        int96[] memory preStems = new int96[](2);
        (preStems[0], ) = sPinto.germinatingDeposits(0);
        (preStems[1], ) = sPinto.germinatingDeposits(1);

        vm.startPrank(receiver);

        // Expect withdraw event
        vm.expectEmit();
        emit ISiloedPinto.Withdraw(receiver, receiver, receiver, assets * 2, shares1 + shares2);

        // withdraw all to silo
        (int96[] memory stems, uint256[] memory amounts) = sPinto.withdrawToSilo(
            assets * 2,
            receiver,
            receiver,
            From.EXTERNAL
        );
        vm.stopPrank();

        // check that the deposits were removed from the deposits array
        assertEq(sPinto.getDepositsLength(), 0);
        assertEq(sPinto.getGerminatingDepositsLength(), 0);
        // check that the stems returned are the same as the pre stems
        assertEq(stems[0], preStems[0]);
        assertEq(stems[1], preStems[1]);
        // check that the amounts returned are the same as the deposits
        assertEq(amounts[0], assets);
        assertEq(amounts[1], assets);
        // get the deposits from the silo
        (uint256 amount1, uint256 bdv1) = pintoProtocol.getDeposit(receiver, PINTO, stems[0]);
        (uint256 amount2, uint256 bdv2) = pintoProtocol.getDeposit(receiver, PINTO, stems[1]);
        // check that the amounts returned are the same as the deposits
        assertEq(amount1, assets);
        assertEq(amount2, assets);
        // check that the bdv returned is the same as the bdv of the deposits
        assertEq(bdv1, assets); // 1 pinto = 1 bdv
        assertEq(bdv2, assets);
        // all balances are in the form of silo deposits now
        checkBalances(0, 0, 0, 0, receiver);
    }

    ////////////////////////// Redeem to Silo //////////////////////////

    function test_redeemToSilo() public {
        uint256 assets = 100e6;
        // deposit and mint sPinto to receiver external balance
        uint256 shares1 = sPinto.depositAdvanced(assets, receiver, From.EXTERNAL, To.EXTERNAL);
        // call sunrise to get new stems
        proceedAndGm();
        uint256 shares2 = sPinto.depositAdvanced(assets, receiver, From.EXTERNAL, To.EXTERNAL);
        // deposit list [100 100]

        // get the length of the deposits pre withdraw
        // fresh deposits are germinating deposits
        uint256 preLength = sPinto.getGerminatingDepositsLength();
        assertEq(preLength, 2);
        // get the stems of the deposits
        int96[] memory preStems = new int96[](2);
        (preStems[0], ) = sPinto.germinatingDeposits(0);
        (preStems[1], ) = sPinto.germinatingDeposits(1);

        vm.startPrank(receiver);

        // Expect withdraw event
        vm.expectEmit();
        emit ISiloedPinto.Withdraw(receiver, receiver, receiver, assets * 2, shares1 + shares2);

        // withdraw all to silo
        (int96[] memory stems, uint256[] memory amounts) = sPinto.redeemToSilo(
            shares1 + shares2,
            receiver,
            receiver,
            From.EXTERNAL
        );
        vm.stopPrank();

        // check that the deposits were removed from the deposits array
        assertEq(sPinto.getDepositsLength(), 0);
        assertEq(sPinto.getGerminatingDepositsLength(), 0);
        // check that the stems returned are the same as the pre stems
        assertEq(preStems[0], stems[0], "preStems[0], stems[0]");
        assertEq(preStems[1], stems[1], "preStems[1], stems[1]");
        // check that the amounts returned are the same as the deposits
        assertEq(amounts[0], amounts[0], "amounts[0], amounts[0]");
        assertEq(amounts[1], amounts[1], "amounts[1], amounts[1]");
        // get the deposits from the silo
        (uint256 amount1, uint256 bdv1) = pintoProtocol.getDeposit(receiver, PINTO, stems[0]);
        (uint256 amount2, uint256 bdv2) = pintoProtocol.getDeposit(receiver, PINTO, stems[1]);
        // check that the amounts returned are the same as the deposits
        assertEq(amount1, assets);
        assertEq(amount2, assets);
        // check that the bdv returned is the same as the bdv of the deposits
        assertEq(bdv1, assets); // 1 pinto = 1 bdv
        assertEq(bdv2, assets);
        // all balances are in the form of silo deposits now
        checkBalances(0, 0, 0, 0, receiver);
    }
}
