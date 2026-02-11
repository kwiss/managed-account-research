// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IDelay - Zodiac Delay module interface
/// @notice Interface for the Zodiac Delay modifier that enforces a timelock on transactions
interface IDelay {
    /// @notice Execute a transaction from an enabled module (queues it with delay)
    /// @param to Destination address
    /// @param value Ether value
    /// @param data Data payload
    /// @param operation Operation type (0 = Call, 1 = DelegateCall)
    /// @return success Whether the transaction was queued/executed successfully
    function execTransactionFromModule(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation
    ) external returns (bool success);

    /// @notice Set the cooldown period before a queued transaction can be executed
    /// @param cooldown Cooldown in seconds
    function setTxCooldown(uint256 cooldown) external;

    /// @notice Set the expiration time for a queued transaction
    /// @param expiration Expiration in seconds after cooldown
    function setTxExpiration(uint256 expiration) external;

    /// @notice Set the transaction nonce (used for cancellation by owner)
    /// @param nonce New nonce value — skips all queued transactions before this nonce
    function setTxNonce(uint256 nonce) external;

    /// @notice Returns the current cooldown period
    /// @return Cooldown in seconds
    function txCooldown() external view returns (uint256);

    /// @notice Returns the current expiration period
    /// @return Expiration in seconds
    function txExpiration() external view returns (uint256);

    /// @notice Returns the current transaction nonce
    /// @return Current nonce
    function txNonce() external view returns (uint256);

    /// @notice Returns the hash of a queued transaction at a given nonce
    /// @param nonce The nonce to query
    /// @return Transaction hash
    function txHash(uint256 nonce) external view returns (bytes32);

    /// @notice Returns the creation timestamp of a queued transaction
    /// @param nonce The nonce to query
    /// @return Timestamp when the transaction was queued
    function txCreatedAt(uint256 nonce) external view returns (uint256);

    /// @notice Returns the next nonce for queuing transactions
    /// @return Queue nonce
    function queueNonce() external view returns (uint256);
}
