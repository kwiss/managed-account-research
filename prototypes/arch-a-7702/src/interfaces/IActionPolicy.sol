// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IActionPolicy - Interface for action validation policies.
/// @notice Policies validate the parameters of a specific DeFi action (e.g., swap, supply, approve).
interface IActionPolicy {
    /// @notice Validates an action's parameters.
    /// @param id A unique identifier for the session/permission context.
    /// @param account The smart account performing the action.
    /// @param target The target contract being called.
    /// @param value The ETH value sent with the call.
    /// @param data The calldata of the action.
    /// @return A status code (0 = valid, non-zero = reason for rejection).
    function checkAction(
        bytes32 id,
        address account,
        address target,
        uint256 value,
        bytes calldata data
    ) external returns (uint256);
}
