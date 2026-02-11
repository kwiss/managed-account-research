// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IRoles - Zodiac Roles v2 module interface
/// @notice Interface for the Zodiac Roles modifier that enforces granular permissions
interface IRoles {
    /// @notice Execute a transaction with role-based permission checks
    /// @param to Destination address
    /// @param value Ether value
    /// @param data Data payload
    /// @param operation Operation type (0 = Call, 1 = DelegateCall)
    /// @param roleKey Identifier for the role to check against
    /// @param shouldRevert If true, reverts on permission failure instead of returning false
    /// @return success Whether the execution succeeded
    function execTransactionWithRole(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint16 roleKey,
        bool shouldRevert
    ) external returns (bool success);

    /// @notice Assign roles to a member
    /// @param member Address to assign roles to
    /// @param roleKeys Array of role keys to assign
    /// @param memberOf Array of booleans indicating membership for each role
    function assignRoles(
        address member,
        uint16[] calldata roleKeys,
        bool[] calldata memberOf
    ) external;

    /// @notice Allow a target contract for a specific role
    /// @param roleKey Role key
    /// @param targetAddress Target contract address to scope
    function scopeTarget(uint16 roleKey, address targetAddress) external;

    /// @notice Scope a function selector on a target for a role
    /// @param roleKey Role key
    /// @param targetAddress Target contract address
    /// @param selector Function selector to scope
    /// @param isWildcarded If true, allows any parameters for this function
    function scopeFunction(
        uint16 roleKey,
        address targetAddress,
        bytes4 selector,
        bool isWildcarded
    ) external;
}
