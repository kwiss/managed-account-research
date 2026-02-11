// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IRoles} from "../../src/interfaces/IRoles.sol";

/// @title MockRoles - Simplified Zodiac Roles v2 for testing
/// @notice Simulates permission checks per role and optionally forwards to target module (e.g. Delay)
contract MockRoles is IRoles {
    /// @notice The target module to forward approved transactions to (e.g. Delay module)
    /// If set to address(0), no forwarding occurs (basic mode)
    address public targetModule;
    // roleKey => target => selector => allowed
    mapping(uint16 => mapping(address => mapping(bytes4 => bool))) public allowedFunctions;
    // roleKey => target => wildcarded (all functions allowed)
    mapping(uint16 => mapping(address => bool)) public scopedTargets;
    // roleKey => member => isMember
    mapping(uint16 => mapping(address => bool)) public members;

    // Track last execution for assertions
    address public lastExecTo;
    uint256 public lastExecValue;
    bytes public lastExecData;
    uint8 public lastExecOperation;
    uint16 public lastExecRoleKey;
    uint256 public execCount;

    bool public shouldSucceed = true;

    error PermissionDenied(uint16 roleKey, address target, bytes4 selector);

    function setTargetModule(address _targetModule) external {
        targetModule = _targetModule;
    }

    function setPermission(uint16 roleKey, address target, bytes4 selector, bool allowed) external {
        allowedFunctions[roleKey][target][selector] = allowed;
    }

    function setShouldSucceed(bool _shouldSucceed) external {
        shouldSucceed = _shouldSucceed;
    }

    function execTransactionWithRole(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint16 roleKey,
        bool shouldRevert
    ) external override returns (bool) {
        lastExecTo = to;
        lastExecValue = value;
        lastExecData = data;
        lastExecOperation = operation;
        lastExecRoleKey = roleKey;
        execCount++;

        // Check if this function is allowed for this role
        bytes4 selector = bytes4(data[:4]);
        bool allowed = allowedFunctions[roleKey][to][selector] || scopedTargets[roleKey][to];

        if (!allowed) {
            if (shouldRevert) {
                revert PermissionDenied(roleKey, to, selector);
            }
            return false;
        }

        if (!shouldSucceed) {
            if (shouldRevert) revert("MockRoles: forced failure");
            return false;
        }

        // Forward to target module if set (simulates Roles -> Delay chain)
        if (targetModule != address(0)) {
            (bool fwdSuccess,) = targetModule.call(
                abi.encodeWithSignature(
                    "execTransactionFromModule(address,uint256,bytes,uint8)",
                    to, value, data, operation
                )
            );
            return fwdSuccess;
        }

        return true;
    }

    function assignRoles(
        address member,
        uint16[] calldata roleKeys,
        bool[] calldata memberOf
    ) external override {
        for (uint256 i = 0; i < roleKeys.length; i++) {
            members[roleKeys[i]][member] = memberOf[i];
        }
    }

    function scopeTarget(uint16 roleKey, address targetAddress) external override {
        scopedTargets[roleKey][targetAddress] = true;
    }

    function scopeFunction(
        uint16 roleKey,
        address targetAddress,
        bytes4 selector,
        bool isWildcarded
    ) external override {
        if (isWildcarded) {
            scopedTargets[roleKey][targetAddress] = true;
        } else {
            allowedFunctions[roleKey][targetAddress][selector] = true;
        }
    }
}
