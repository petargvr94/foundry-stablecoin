// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {Script} from "forge-std/Script.sol";
import {DecentralizedStableCoin} from "../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../src/DSCEngine.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

contract DeployDSC is Script {
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function run() external returns(DecentralizedStableCoin, DSCEngine, HelperConfig) {
     HelperConfig helperConfig = new HelperConfig();
     (address wethUsdPriceFeed, address wbtcUsdPriceFeed, address weth, address wbtc, uint256 deployerKey) =
            helperConfig.activeNetworkConfig();
        tokenAddresses = [weth, wbtc];
        priceFeedAddresses = [wethUsdPriceFeed,wbtcUsdPriceFeed];

     vm.startBroadcast();
     DecentralizedStableCoin dsc = new DecentralizedStableCoin();
     DSCEngine engine = new DSCEngine(tokenAddresses,priceFeedAddresses, address(dsc));

    dsc.transferOwnership(address(engine));
    
     vm.stopBroadcast();

     return (dsc,engine,helperConfig);
    }
}

// SEE HOW THINGS ARE WORKING IN THE
// 1.HELPER CONFIG -> THE CODE THERE ITSELF AND THE MOCKS AS WELL
// 2.TRY TO UNDERSTAND HOW THE MOCKS THEMSELVES WORK AND WHAT IS THEIR PURPOSE
// 3.THEN GET BACK TO THE CODE HERE AND TRY TO UNDERSTAND HOW THAT SCRIPT WORKS
// 4.TRY TO UNDERSTAND WHAT OWNERSHIP MEANS, WHAT IS THE PURPOSE OF OWNERSHIP IN THE DSC CONTRACT
// AND WHAT IS THE PURPOSE OF TRANSFERRING OWNERSHIP HERE.