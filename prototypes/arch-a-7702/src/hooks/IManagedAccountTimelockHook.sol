// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IManagedAccountTimelockHook - Interface for the timelock hook on ManagedAccounts.
/// @notice Queues operator operations with a cooldown delay; owners can cancel or bypass.
interface IManagedAccountTimelockHook {
    // ──────────────────── Structs ────────────────────

    struct TimelockConfig {
        uint128 cooldownPeriod;
        uint128 expirationPeriod;
    }

    struct QueueEntry {
        uint48 queuedAt;
        uint48 executeAfter;
        uint48 expiresAt;
        address operator;
        bool exists;
    }

    // ──────────────────── Events ────────────────────

    event OperationQueued(
        address indexed account,
        bytes32 indexed execHash,
        address operator,
        uint48 executeAfter,
        uint48 expiresAt
    );

    event OperationExecuted(
        address indexed account,
        bytes32 indexed execHash,
        address operator
    );

    event OperationCancelled(
        address indexed account,
        bytes32 indexed execHash
    );

    event TimelockConfigured(
        address indexed account,
        uint128 cooldownPeriod,
        uint128 expirationPeriod
    );

    event SelectorWhitelisted(
        address indexed account,
        address indexed target,
        bytes4 selector,
        bool immediate
    );

    // ──────────────────── Errors ────────────────────

    error OperationQueued_WaitForCooldown(bytes32 execHash, uint48 executeAfter);
    error OperationNotQueued(bytes32 execHash);
    error OperationExpired(bytes32 execHash, uint48 expiresAt);
    error CooldownNotElapsed(bytes32 execHash, uint48 executeAfter);
    error OnlyAccount();
    error InvalidConfig();
    error NotInitialized();
    error AlreadyQueued(bytes32 execHash);
    error AlreadyInstalled();
    error Unauthorized();
    error InvalidOwner();
    error ConfigExceedsUint48Bounds();
    error UnauthorizedOperator(address actual, address expected);

    // ──────────────────── Functions ────────────────────

    /// @notice Queues an operation for delayed execution.
    /// @dev Only callable by the operator or the account itself. [C-02]
    /// @param account The account the operation is for.
    /// @param operator The operator submitting the operation.
    /// @param msgValue The ETH value of the operation.
    /// @param msgData The calldata of the operation.
    function queueOperation(
        address account,
        address operator,
        uint256 msgValue,
        bytes calldata msgData
    ) external;

    /// @notice Cancels a queued operation. Only callable by an initialized account.
    /// @param execHash The hash of the queued execution.
    function cancelExecution(bytes32 execHash) external;

    /// @notice Sets the timelock configuration for the calling account.
    /// @param cooldownPeriod Time (seconds) an operation must wait before execution.
    /// @param expirationPeriod Time (seconds) after which a queued operation expires.
    function setTimelockConfig(uint128 cooldownPeriod, uint128 expirationPeriod) external;

    /// @notice Marks a target+selector as immediate (bypasses timelock) for the calling account.
    /// @param target The target contract address.
    /// @param selector The function selector.
    /// @param immediate Whether to allow immediate execution.
    function setImmediateSelector(address target, bytes4 selector, bool immediate) external;

    /// @notice Returns the queue entry for a given account and execution hash.
    /// @param account The account address.
    /// @param execHash The execution hash.
    /// @return entry The queue entry.
    function getQueueEntry(
        address account,
        bytes32 execHash
    ) external view returns (QueueEntry memory entry);

    /// @notice Returns the timelock configuration for a given account.
    /// @param account The account address.
    /// @return config The timelock config.
    function getTimelockConfig(
        address account
    ) external view returns (TimelockConfig memory config);

    /// @notice Checks if a target+selector is marked as immediate for a given account.
    /// @param account The account address.
    /// @param target The target contract address.
    /// @param selector The function selector.
    /// @return True if the selector is immediate.
    function isImmediateSelector(
        address account,
        address target,
        bytes4 selector
    ) external view returns (bool);

    /// @notice Computes the execution hash from the call parameters.
    /// @param account The account address.
    /// @param msgSender The caller address.
    /// @param msgValue The ETH value.
    /// @param msgData The calldata.
    /// @return The computed hash.
    function computeExecHash(
        address account,
        address msgSender,
        uint256 msgValue,
        bytes calldata msgData
    ) external view returns (bytes32);
}
