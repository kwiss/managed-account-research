// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IManagedAccountTimelockHook
/// @notice Interface for the ManagedAccount timelock hook
/// @dev Enforces time-delayed execution for non-owner operations with owner cancellation rights
interface IManagedAccountTimelockHook {
    // ─── Structs ─────────────────────────────────────────────────────────────

    /// @notice Configuration for the timelock per account
    struct TimelockConfig {
        /// @dev Minimum time (seconds) that must pass after queueing before execution
        uint256 cooldown;
        /// @dev Time window (seconds) after cooldown during which execution is valid
        uint256 expiration;
        /// @dev Address of the Safe account (used to check owner status)
        address safeAccount;
        /// @dev Generation nonce — incremented on each uninstall to invalidate stale queue entries
        uint256 generation;
    }

    /// @notice Represents a queued operation
    struct QueuedOperation {
        /// @dev Timestamp when the operation was queued
        uint256 queuedAt;
        /// @dev Whether the operation has been executed or cancelled
        bool consumed;
        /// @dev Generation nonce at the time of queuing
        uint256 generation;
    }

    // ─── Events ──────────────────────────────────────────────────────────────

    /// @notice Emitted when an operation is queued
    event OperationQueued(address indexed account, bytes32 indexed operationHash, uint256 queuedAt);

    /// @notice Emitted when a queued operation is executed
    event OperationExecuted(address indexed account, bytes32 indexed operationHash);

    /// @notice Emitted when a queued operation is cancelled by an owner
    event OperationCancelled(address indexed account, bytes32 indexed operationHash);

    /// @notice Emitted when timelock config is updated
    event TimelockConfigSet(address indexed account, uint256 cooldown, uint256 expiration);

    /// @notice Emitted when an immediate selector is set
    event ImmediateSelectorSet(address indexed account, address indexed target, bytes4 selector, bool allowed);

    // ─── Errors ──────────────────────────────────────────────────────────────

    /// @notice Operation is not yet ready (cooldown not elapsed)
    error OperationNotReady(bytes32 operationHash, uint256 readyAt);

    /// @notice Operation has expired
    error OperationExpired(bytes32 operationHash, uint256 expiredAt);

    /// @notice Operation not found or already consumed
    error OperationNotFound(bytes32 operationHash);

    /// @notice Only Safe owners can call this function
    error OnlyOwner();

    /// @notice Invalid timelock configuration
    error InvalidTimelockConfig();

    /// @notice Cooldown is below the minimum required
    error CooldownTooShort();

    /// @notice Operation is already queued and not yet consumed
    error OperationAlreadyQueued(bytes32 operationHash);

    /// @notice Account not initialized
    error NotInitialized();

    /// @notice Caller is not authorized
    error UnauthorizedCaller();

    /// @notice Unsupported execution mode (only single execution is supported)
    error UnsupportedExecutionMode();

    /// @notice Invalid execution calldata
    error InvalidExecutionCalldata();

    // ─── Functions ───────────────────────────────────────────────────────────

    /// @notice Queue an operation for time-delayed execution
    /// @param account The account address (Safe) this operation belongs to
    /// @param operator The operator who will execute the operation
    /// @param msgData The full execution calldata
    function queueOperation(address account, address operator, bytes calldata msgData) external;

    /// @notice Cancel a queued operation (only callable by Safe owners via the account)
    /// @param msgSender The original caller address (must be a Safe owner)
    /// @param operationHash The hash of the operation to cancel
    function cancelExecution(address msgSender, bytes32 operationHash) external;

    /// @notice Set the timelock configuration for the calling account
    /// @param cooldown Minimum delay in seconds
    /// @param expiration Validity window in seconds after cooldown
    function setTimelockConfig(uint256 cooldown, uint256 expiration) external;

    /// @notice Set whether a target+selector pair can bypass the timelock
    /// @param target The target contract address
    /// @param selector The function selector
    /// @param allowed Whether this combination is immediate
    function setImmediateSelector(address target, bytes4 selector, bool allowed) external;

    /// @notice Get the timelock configuration for an account
    /// @param account The account address
    /// @return config The timelock configuration
    function getTimelockConfig(address account) external view returns (TimelockConfig memory config);

    /// @notice Get a queued operation
    /// @param account The account address
    /// @param operationHash The operation hash
    /// @return operation The queued operation details
    function getQueuedOperation(address account, bytes32 operationHash)
        external
        view
        returns (QueuedOperation memory operation);

    /// @notice Check if a target+selector pair is immediate for an account
    /// @param account The account address
    /// @param target The target contract address
    /// @param selector The function selector
    /// @return True if the pair is immediate
    function isImmediateSelector(address account, address target, bytes4 selector) external view returns (bool);
}
