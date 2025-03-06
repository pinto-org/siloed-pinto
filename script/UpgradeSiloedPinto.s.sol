// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import "openzeppelin-foundry-upgrades/Upgrades.sol";
import {SiloedPinto} from "src/SiloedPinto.sol";
import {SiloedPintoV2} from "test/mocks/SiloedPintoV2.sol";

contract UpgradeSiloedPinto is Script {
    address constant INIT_OWNER = 0x2cf82605402912C6a79078a9BBfcCf061CbfD507;

    function run() external {
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        // The transparent proxy address
        address proxy = 0x07B75F35E90Eb114035d3c67AC7738F11FB70a26;

        // Upgrade the proxy to current SiloedPinto version.
        // This also validates that the new implementation is compatible.
        Upgrades.upgradeProxy(proxy, "SiloedPintoV2.sol", "", INIT_OWNER);

        address implAddr = Upgrades.getImplementationAddress(proxy);
        console.log("Implementation Address after upgrade: ", implAddr);

        address adminAddress = Upgrades.getAdminAddress(proxy);
        console.log("Admin Contract Address: ", adminAddress);

        // Get the instance of the contract
        SiloedPinto instance = SiloedPinto(proxy);

        // Log and verify the updated value
        console.log("Version after upgrade: ", instance.version());
        vm.stopBroadcast();
    }
}
