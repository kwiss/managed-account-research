// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDelay} from "../../src/interfaces/IDelay.sol";

/// @title MockDelay - Simplified Zodiac Delay module for testing
/// @notice Simulates FIFO queue with cooldown, expiration, and nonce-based cancellation
contract MockDelay is IDelay {
    struct QueuedTx {
        bytes32 txHash;
        uint256 createdAt;
    }

    /// @notice The avatar (Safe) that this module controls
    address public avatar;

    /// @notice Modules enabled on this delay module
    mapping(address => bool) public enabledModules;

    uint256 private _txCooldown;
    uint256 private _txExpiration;
    uint256 private _txNonce; // execution nonce
    uint256 private _queueNonce; // queue nonce

    mapping(uint256 => QueuedTx) public queuedTxs;

    error NotEnabled(address module);
    error TxNotQueued(uint256 nonce);
    error CooldownNotMet(uint256 nonce);
    error TxExpired(uint256 nonce);
    error HashMismatch(uint256 nonce);

    constructor(address _avatar) {
        avatar = _avatar;
        _txCooldown = 0;
        _txExpiration = type(uint256).max;
    }

    function enableModule(address module) external {
        enabledModules[module] = true;
    }

    function disableModule(address module) external {
        enabledModules[module] = false;
    }

    /// @notice Queue a transaction from an enabled module
    /// @dev In the real Delay module, this queues the tx. A separate call executes it after cooldown.
    /// For simplicity, this mock queues and we provide executeNext() to execute.
    function execTransactionFromModule(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation
    ) external override returns (bool) {
        if (!enabledModules[msg.sender]) revert NotEnabled(msg.sender);

        bytes32 hash = _getTxHash(to, value, data, operation);
        queuedTxs[_queueNonce] = QueuedTx({
            txHash: hash,
            createdAt: block.timestamp
        });
        _queueNonce++;

        return true;
    }

    /// @notice Execute the next queued transaction (after cooldown)
    /// @param to Must match the queued transaction
    /// @param value Must match the queued transaction
    /// @param data Must match the queued transaction
    /// @param operation Must match the queued transaction
    function executeNextTx(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation
    ) external returns (bool) {
        if (_txNonce >= _queueNonce) revert TxNotQueued(_txNonce);

        QueuedTx storage queued = queuedTxs[_txNonce];
        if (queued.createdAt == 0) revert TxNotQueued(_txNonce);

        // Check cooldown
        if (block.timestamp < queued.createdAt + _txCooldown) {
            revert CooldownNotMet(_txNonce);
        }

        // Check expiration
        if (_txExpiration != type(uint256).max && block.timestamp > queued.createdAt + _txCooldown + _txExpiration) {
            revert TxExpired(_txNonce);
        }

        // Verify hash
        bytes32 hash = _getTxHash(to, value, data, operation);
        if (hash != queued.txHash) revert HashMismatch(_txNonce);

        _txNonce++;

        // Execute on the avatar (Safe)
        (bool success,) = avatar.call(
            abi.encodeWithSignature(
                "execTransactionFromModule(address,uint256,bytes,uint8)",
                to, value, data, operation
            )
        );
        return success;
    }

    // ─── IDelay Setters ──────────────────────────────────────────────

    function setTxCooldown(uint256 cooldown) external override {
        _txCooldown = cooldown;
    }

    function setTxExpiration(uint256 expiration) external override {
        _txExpiration = expiration;
    }

    /// @notice Set the transaction nonce — skips all queued txs before this nonce (cancellation)
    function setTxNonce(uint256 nonce_) external override {
        require(nonce_ > _txNonce, "MockDelay: can only advance nonce");
        require(nonce_ <= _queueNonce, "MockDelay: cannot skip beyond queue");
        _txNonce = nonce_;
    }

    // ─── IDelay Getters ──────────────────────────────────────────────

    function txCooldown() external view override returns (uint256) {
        return _txCooldown;
    }

    function txExpiration() external view override returns (uint256) {
        return _txExpiration;
    }

    function txNonce() external view override returns (uint256) {
        return _txNonce;
    }

    function txHash(uint256 nonce_) external view override returns (bytes32) {
        return queuedTxs[nonce_].txHash;
    }

    function txCreatedAt(uint256 nonce_) external view override returns (uint256) {
        return queuedTxs[nonce_].createdAt;
    }

    function queueNonce() external view override returns (uint256) {
        return _queueNonce;
    }

    // ─── Internal ────────────────────────────────────────────────────

    function _getTxHash(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(to, value, keccak256(data), operation));
    }
}
