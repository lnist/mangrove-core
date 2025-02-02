// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {Deployer} from "mgv_script/lib/Deployer.sol";
import {PixieUSDC} from "mgv_src/toy/PixieUSDC.sol";

/**
 * @notice deploys a PixieUSDC instance
 */

contract PixieUSDCDeployer is Deployer {
  function run() public {
    innerRun({admin: envAddressOrName("MGV_GOVERNANCE", "MgvGovernance")});
    outputDeployment();
  }

  function innerRun(address admin) public {
    broadcast();
    PixieUSDC pixie = new PixieUSDC(admin);
    fork.set("PxUSDC", address(pixie));
  }
}
