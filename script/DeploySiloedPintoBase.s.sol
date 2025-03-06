// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import "openzeppelin-foundry-upgrades/Upgrades.sol";
import {SiloedPinto} from "src/SiloedPinto.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IPintoProtocolExtended, TokenDepositId, Deposit, To} from "test/interfaces/IPintoProtocolExtended.sol";

/**
 * @title DeploySiloedPintoBase
 * @notice Deploys the upgradeable ERC4626 SiloedPinto proxy and implementation on Base.
 * Seeds the sPinto token with initial deposits from the Silo.
 * @dev This script is designed to be ran once and only on the Base Chain since this is
 * where the core protocol lives.
 * - When deploying in other chains, the token should be a plain OFT ERC20 token.
 * - To get the same address for the SiloedPinto contract across all chains,
 * make sure that the same deployer is used and the deployment transaction has a nonce of 1.
 */
contract DeploySiloedPintoBase is Script {
    address PCM = address(0x2cf82605402912C6a79078a9BBfcCf061CbfD507);
    address DEPLOYER = address(0xf6785D3ff59db81D90dEC9699E6f54c625ad68Dc);

    IPintoProtocolExtended pintoProtocol =
        IPintoProtocolExtended(0xD1A0D188E861ed9d15773a2F3574a2e94134bA8f);
    IERC20 pinto = IERC20(0xb170000aeeFa790fa61D6e837d1035906839a3c8);

    function run() external {
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));

        // Configuration.
        uint256 maxTriggerPrice = 1.01e6;
        uint256 slippageRatio = 0.01e18; // 1%
        uint256 floodTranchRatio = 0.1e18; // 10%
        uint256 vestingPeriod = 2 hours;
        uint256 minSize = 1e6;
        uint256 targetMinSize = 10_000e6;

        address proxy = Upgrades.deployTransparentProxy(
            "SiloedPinto.sol",
            PCM, // initial owner, who can call the proxy admin
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
        console.log("sPINTO Deployed");
        console.log("---------------------------");
        console.log("Proxy Address: ", proxy);

        // Get the instance of the contract
        SiloedPinto sPinto = SiloedPinto(proxy);

        // Get the implementation address of the proxy
        address implAddr = Upgrades.getImplementationAddress(proxy);
        console.log("Implementation Address: ", implAddr);

        // Get the proxy admin contract address
        address adminAddress = Upgrades.getAdminAddress(proxy);
        console.log("Admin Address: ", adminAddress);

        // Get the owner of the proxy admin contract
        address adminOwner = OwnableUpgradeable(adminAddress).owner();
        console.log("Admin Owner Address: ", adminOwner);

        // Get the owner of the contract
        address owner = sPinto.owner();
        console.log("Owner Address: ", owner);

        // Verify initial value is as expected
        console.log("Deployed Version: ", sPinto.version());
        console.log("---------------------------");

        ///////////////// Seed Deposit From Silo /////////////////

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

        //////////////////////////// Seed Plain Deposit ////////////////////////////
        // approve pinto to be spent by sPinto
        // pinto.approve(address(sPinto), 100e6);
        // Perform initial deposit of 100e6 pinto to mitigate direct silo deposit
        // donation attack that messes up exchange rate if yield is accrued with no underlying pdv
        // sPinto.deposit(100e6, PCM);

        vm.stopBroadcast();
    }

    ///////////////// Helper Function from LibBytes in protocol /////////////////

    function unpackAddressAndStem(uint256 data) internal pure returns (address, int96) {
        return (address(uint160(data >> 96)), int96(int256(data)));
    }
}
