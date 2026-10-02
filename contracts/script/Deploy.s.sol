// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Tock} from "../src/Tock.sol";

/// arc-forge script script/Deploy.s.sol --rpc-url arc --broadcast --private-key $PRIVATE_KEY
contract Deploy is Script {
    function run() external {
        vm.broadcast();
        Tock tock = new Tock();
        console.log("Tock:", address(tock));
    }
}
