// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MockSensorNet
 * @notice Mock oracle for testing — simulates Netclawd's SensorNet
 */
contract MockSensorNet {
    int256 public temperature;
    address public owner;

    constructor(int256 _initialTemp) {
        temperature = _initialTemp;
        owner = msg.sender;
    }

    function setTemperature(int256 _temp) external {
        temperature = _temp;
    }

    function getTemperature() external view returns (int256) {
        return temperature;
    }
}
