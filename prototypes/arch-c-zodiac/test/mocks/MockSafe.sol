// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISafe} from "../../src/interfaces/ISafe.sol";

/// @title MockSafe - Simplified Safe for testing
/// @notice Tracks enabled modules and simulates execTransactionFromModule
contract MockSafe is ISafe {
    mapping(address => bool) public enabledModules;
    mapping(address => bool) public owners;
    address[] private _owners;
    uint256 private _threshold;

    // Track calls for assertions
    address public lastExecTo;
    uint256 public lastExecValue;
    bytes public lastExecData;
    uint8 public lastExecOperation;
    bool public execShouldSucceed = true;
    uint256 public execFromModuleCount;

    constructor() {
        _threshold = 1;
    }

    function addOwner(address owner) external {
        if (!owners[owner]) {
            owners[owner] = true;
            _owners.push(owner);
        }
    }

    function setThreshold(uint256 threshold_) external {
        _threshold = threshold_;
    }

    /// @notice Execute a call as the Safe (for testing module management)
    function exec(address to, bytes calldata data) external returns (bool success, bytes memory returnData) {
        (success, returnData) = to.call(data);
    }

    // ─── ISafe Implementation ────────────────────────────────────────

    function execTransaction(
        address, uint256, bytes calldata, uint8, uint256, uint256, uint256, address, address payable, bytes calldata
    ) external payable override returns (bool) {
        return true;
    }

    function execTransactionFromModule(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation
    ) external override returns (bool) {
        if (!enabledModules[msg.sender]) return false;

        lastExecTo = to;
        lastExecValue = value;
        lastExecData = data;
        lastExecOperation = operation;
        execFromModuleCount++;

        if (!execShouldSucceed) return false;

        if (data.length > 0) {
            (bool success,) = to.call{value: value}(data);
            return success;
        }
        return true;
    }

    function enableModule(address module) external override {
        enabledModules[module] = true;
    }

    function disableModule(address, address module) external override {
        enabledModules[module] = false;
    }

    function getOwners() external view override returns (address[] memory) {
        return _owners;
    }

    function isOwner(address owner) external view override returns (bool) {
        return owners[owner];
    }

    function getThreshold() external view override returns (uint256) {
        return _threshold;
    }

    function nonce() external pure override returns (uint256) {
        return 0;
    }

    receive() external payable {}
}
