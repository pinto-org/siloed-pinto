/**
 * SPDX-License-Identifier: MIT
 **/

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import "openzeppelin-foundry-upgrades/Upgrades.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPintoProtocol, From, To, TokenDepositId} from "src/interfaces/IPintoProtocol.sol";
import {SiloedPinto} from "src/SiloedPinto.sol";
import {SiloedPintoV2} from "test/mocks/SiloedPintoV2.sol";
import "forge-std/console.sol";
import {TestHelpers} from "test/TestHelpers.sol";

contract SiloedPintoDeploymentTest is TestHelpers {
    address DEPLOYER = address(0xf6785D3ff59db81D90dEC9699E6f54c625ad68Dc);

    function setUp() public {
        createForks();
        // fork when deltaP is negative to exclude earned pinto logic
        vm.selectFork(negativeDeltaPFork);
        // set the environment in the current fork
        _setUp();
        // seed liquidity with silo deposits
        seedFromSiloDeposits(DEPLOYER);
    }

    function test_DeploymentSuccesful() public view {
        // Get the owner of the sPinto contract
        address owner = sPinto.owner();
        // Ensure the owner is the PCM
        assertEq(owner, PCM);

        // Get the admin address of the proxy
        address adminAddress = Upgrades.getAdminAddress(sPintoProxy);
        // Ensure the admin address is valid
        assertFalse(adminAddress == address(0));

        // Verify initial values are as expected
        assertEq(sPinto.version(), "1.0.1");

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

        // Verify the Seed was succesful
        assertEq(sPinto.totalSupply(), 10_000e18);
        assertEq(sPinto.balanceOf(PCM), 10_000e18);
        assertEq(sPinto.underlyingPdv(), 10_000e6);
        assertEq(sPinto.totalAssets(), 10_000e6);
    }

    /// @dev Seeds initial pinto into sPinto from the accounts silo deposits
    function seedFromSiloDeposits(address deployer) public {
        vm.startPrank(deployer);

        // mint 10k pinto to the deployer
        deal(address(pinto), address(deployer), 10_000e6);

        // make 2 deposits of 5k pinto each
        // to simulate the silo deposits that the deploy will hold
        depositToSilo(5000e6);
        depositToSilo(5000e6);

        // get the deposits for the deployer
        TokenDepositId memory deposits = pintoProtocol.getTokenDepositsForAccount(
            DEPLOYER,
            address(pinto)
        );

        int96[] memory stems = new int96[](deposits.depositIds.length);
        uint256[] memory amounts = new uint256[](deposits.depositIds.length);
        uint256 sumAmounts;
        for (uint256 i = 0; i < deposits.depositIds.length; i++) {
            // get stem from deposit id
            (, int96 stem) = unpackAddressAndStem(deposits.depositIds[i]);
            stems[i] = stem;
            // get the amount from the deposit list
            uint256 amount = deposits.tokenDeposits[i].amount;
            amounts[i] = amount;
            sumAmounts += amount;
        }

        // approve pinto silo deposits to be spent by sPinto
        pintoProtocol.approveDeposit(address(sPinto), address(pinto), sumAmounts);

        // deposit using silo deposits, send sPinto to the PCM external balance
        sPinto.depositFromSilo(stems, amounts, PCM, To.EXTERNAL);

        vm.stopPrank();
    }

    ///////////////// Helper Function from LibBytes in protocol /////////////////

    function unpackAddressAndStem(uint256 data) public pure returns (address, int96) {
        return (address(uint160(data >> 96)), int96(int256(data)));
    }
}
