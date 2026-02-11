// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PackedUserOperation} from "../types/PackedUserOperation.sol";

/// @title IEntryPoint - ERC-4337 EntryPoint interface
/// @notice Minimal interface for the ERC-4337 EntryPoint contract
interface IEntryPoint {
    /// @notice Execute a batch of UserOperations
    /// @param ops Array of packed user operations
    /// @param beneficiary Address to receive gas refunds
    function handleOps(PackedUserOperation[] calldata ops, address payable beneficiary) external;

    /// @notice Generate the hash of a UserOperation
    /// @param userOp The user operation
    /// @return The hash of the user operation
    function getUserOpHash(PackedUserOperation calldata userOp) external view returns (bytes32);
}
