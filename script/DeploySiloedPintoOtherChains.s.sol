// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import "openzeppelin-foundry-upgrades/Upgrades.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockOFT} from "test/mocks/MockOFT.sol";

/**
 * @title DeploySiloedPintoOther
 * @notice Deploy a SiloedPinto OFT contract with the same address as the Base chain on other networks.
 */
contract DeploySiloedPintoOther is Script {
    address PCM = address(0x2cf82605402912C6a79078a9BBfcCf061CbfD507);
    address DEPLOYER = address(0xf6785D3ff59db81D90dEC9699E6f54c625ad68Dc);

    IERC20 pinto = IERC20(0xb170000aeeFa790fa61D6e837d1035906839a3c8);

    function run() external {
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));

        // increase the nonce by doing a zero ether transfer to the 0 address
        payable(address(0)).call{value: 0}("");

        // deploy a standard ERC20 token for testing
        // change this to a LayerZero OFT when needed
        MockOFT token = new MockOFT();

        console.log("---------------------------");
        console.log("Token Address: ", address(token));
        console.log("Token Name: ", token.name());
        console.log("Token Symbol: ", token.symbol());
        console.log("---------------------------");

        vm.stopBroadcast();
    }
}
