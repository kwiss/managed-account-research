// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IActionPolicy
/// @notice Interface for SmartSession action policy contracts
/// @dev Policies validate specific parameters of DeFi operations before execution
interface IActionPolicy {
    /// @notice Check whether an action is allowed by this policy
    /// @param account The smart account executing the action
    /// @param target The target contract being called
    /// @param value The ETH value being sent
    /// @param callData The calldata being sent to the target
    /// @return valid True if the action passes policy checks
    function checkAction(address account, address target, uint256 value, bytes calldata callData)
        external
        returns (bool valid);
}
