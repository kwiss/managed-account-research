// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PackedUserOperation} from "../types/PackedUserOperation.sol";

/// @title ISafe4337RolesModule - Bridge between ERC-4337 and Zodiac Roles pipeline
/// @notice Interface for the custom module that validates UserOps and routes execution
/// through Zodiac Roles v2 -> Delay -> Safe
interface ISafe4337RolesModule {
    // ─── Structs ─────────────────────────────────────────────────────

    /// @notice Configuration for a registered operator
    /// @param operator The operator's address
    /// @param roleKey The Zodiac Roles v2 role key assigned to this operator
    /// @param active Whether the operator is currently active
    /// @param validUntil ERC-4337 time bound: UserOps are valid until this timestamp (0 = no bound)
    struct OperatorConfig {
        address operator;
        uint16 roleKey;
        bool active;
        uint48 validUntil;
    }

    // ─── Events ──────────────────────────────────────────────────────

    /// @notice Emitted when a new operator is registered
    /// @param operator The operator address
    /// @param roleKey The assigned role key
    /// @param validUntil ERC-4337 time bound
    event OperatorAdded(address indexed operator, uint16 roleKey, uint48 validUntil);

    /// @notice Emitted when an operator is removed
    /// @param operator The operator address
    event OperatorRemoved(address indexed operator);

    /// @notice Emitted when a UserOp is successfully validated
    /// @param operator The operator address extracted from the signature
    /// @param userOpHash The hash of the validated UserOp
    event UserOpValidated(address indexed operator, bytes32 indexed userOpHash);

    /// @notice Emitted when a UserOp is successfully executed through the Zodiac pipeline
    /// @param operator The operator address
    /// @param userOpHash The hash of the executed UserOp
    event UserOpExecuted(address indexed operator, bytes32 indexed userOpHash);

    // ─── Errors ──────────────────────────────────────────────────────

    /// @notice Thrown when an operator is not registered or not active
    error UnauthorizedOperator(address operator);

    /// @notice Thrown when the ECDSA signature is invalid
    error InvalidSignature();

    /// @notice Thrown when execution through the Zodiac pipeline fails
    error ExecutionFailed();

    /// @notice Thrown when the stored userOpHash does not match in executeUserOp
    error UserOpHashMismatch();

    /// @notice Thrown when the chain ID does not match the deployment chain ID
    error ChainIdMismatch();

    // ─── Functions ───────────────────────────────────────────────────

    /// @notice Validate a UserOperation (ERC-4337 IAccount interface)
    /// @param userOp The packed user operation
    /// @param userOpHash Hash of the user operation
    /// @param missingAccountFunds Amount of ETH to prefund the EntryPoint
    /// @return validationData 0 for success, 1 for failure (packed with validAfter/validUntil)
    function validateUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 missingAccountFunds
    ) external returns (uint256 validationData);

    /// @notice Execute a validated UserOp through the Zodiac Roles -> Delay -> Safe pipeline
    /// @param userOp The packed user operation (callData encodes target, value, data)
    /// @param userOpHash Hash of the user operation
    function executeUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash) external;

    /// @notice Register a new operator with a role key (only callable by Safe)
    /// @param operator The operator address to register
    /// @param roleKey The Zodiac Roles v2 role key to assign
    /// @param validUntil ERC-4337 time bound: UserOps valid until this timestamp (0 = no bound)
    function addOperator(address operator, uint16 roleKey, uint48 validUntil) external;

    /// @notice Remove an operator (only callable by Safe)
    /// @param operator The operator address to remove
    function removeOperator(address operator) external;

    /// @notice Set the Zodiac Roles v2 module address
    /// @param rolesModule The Roles module address
    function setRolesModule(address rolesModule) external;
}
