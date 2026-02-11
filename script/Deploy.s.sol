// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/DailyTempMarket.sol";

/**
 * @title Deploy DailyTempMarket to Base Mainnet
 * @notice Deployment script for the Garden Temperature Prediction Market
 *
 * Usage:
 *   forge script script/Deploy.s.sol:DeployDailyTempMarket \
 *     --rpc-url base \
 *     --broadcast \
 *     --verify
 *
 * Required environment variables:
 *   PRIVATE_KEY - Deployer wallet private key
 *   BASESCAN_API_KEY - For contract verification
 *
 * Deployment addresses:
 *   - SensorNet: 0xf873D168e2cD9bAC70140eDD6Cae704Ed05AdEe0
 *   - Keeper (Bankr/Ollie): 0x750b7133318c7d24afaae36eadc27f6d6a2cc60d
 *   - Treasury: 0x750b7133318c7d24afaae36eadc27f6d6a2cc60d (same as keeper for now)
 */
contract DeployDailyTempMarket is Script {
    // Base Mainnet addresses
    address constant SENSOR_NET = 0xf873D168e2cD9bAC70140eDD6Cae704Ed05AdEe0;
    address constant KEEPER = 0x750b7133318c7D24aFAAe36eaDc27F6d6A2cc60d;  // Bankr wallet (Ollie)
    address constant TREASURY = 0x750b7133318c7D24aFAAe36eaDc27F6d6A2cc60d; // House fees go here

    // Initial temperature: 12.10°C (1210 in contract format)
    // Update this to the latest SensorNet reading before deployment!
    int256 constant INITIAL_TEMP = 1210;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        console.log("=== DailyTempMarket Deployment ===");
        console.log("Network: Base Mainnet");
        console.log("SensorNet:", SENSOR_NET);
        console.log("Keeper:", KEEPER);
        console.log("Treasury:", TREASURY);
        console.log("Initial Temp:", uint256(int256(INITIAL_TEMP)), " (12.10 C)");
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        DailyTempMarket market = new DailyTempMarket(
            SENSOR_NET,
            KEEPER,
            TREASURY,
            INITIAL_TEMP
        );

        vm.stopBroadcast();

        console.log("=== Deployment Complete ===");
        console.log("DailyTempMarket deployed to:", address(market));
        console.log("");
        console.log("Next steps:");
        console.log("1. Verify on Basescan (should auto-verify with --verify flag)");
        console.log("2. Update CLAUDE.md with contract address");
        console.log("3. Tell Netclawd the contract is live!");
        console.log("4. Set up keeper automation for 18:00 UTC settlement");
    }
}
