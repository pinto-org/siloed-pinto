/**
 * SPDX-License-Identifier: MIT
 **/

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import "openzeppelin-foundry-upgrades/Upgrades.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPintoProtocol, From, To} from "src/interfaces/IPintoProtocol.sol";
import {SiloedPinto} from "src/SiloedPinto.sol";
import {SiloedPintoV2} from "test/mocks/SiloedPintoV2.sol";
import "forge-std/console.sol";

contract SiloedPintoUpgradeabilityTest is Test {
    uint256 BASE_BLOCK_NUM = 23517171;
    address PINTO_PROTOCOL = address(0xD1A0D188E861ed9d15773a2F3574a2e94134bA8f);
    address INIT_OWNER = address(0x8730AA5f20Fc6b360BD3aC345CFC8451C462Ec7C);

    IERC20 pinto = IERC20(0xb170000aeeFa790fa61D6e837d1035906839a3c8);

    SiloedPinto instance;
    address sPintoProxy;
    address implAddr;
    address adminAddress;
    address user;

    function setUp() public {
        vm.createSelectFork("base", BASE_BLOCK_NUM);
        // Configuration.
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
        instance = SiloedPinto(sPintoProxy);

        // Get the implementation address of the proxy
        implAddr = Upgrades.getImplementationAddress(sPintoProxy);

        // Get the admin address of the proxy
        adminAddress = Upgrades.getAdminAddress(sPintoProxy);

        // Ensure the admin address is valid
        assertFalse(adminAddress == address(0));

        // Verify initial value is as expected
        console.log("Version before upgrade: ", instance.version());
        assertEq(instance.version(), "1.0.1");

        user = makeAddr("user");
    }

    function test_UpgradeToSiloedPintoV2() public {
        vm.startPrank(INIT_OWNER);
        // Upgrade the proxy to SiloedPintoV2
        uint256 x = 10;
        Upgrades.upgradeProxy(
            sPintoProxy,
            "SiloedPintoV2.sol",
            abi.encodeCall(SiloedPintoV2.initialize, (x)),
            INIT_OWNER
        );
        // Get the new implementation address after upgrade
        address implAddrV2 = Upgrades.getImplementationAddress(sPintoProxy);
        // Verify admin address remains unchanged
        assertEq(Upgrades.getAdminAddress(sPintoProxy), adminAddress);
        // Verify implementation address has changed
        assertFalse(implAddr == implAddrV2);
        // Log and verify the updated value
        console.log("Version after upgrade: ", instance.version());
        assertEq(instance.version(), "2.0.0");
        vm.stopPrank();
    }

}
