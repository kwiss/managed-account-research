// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC7579Hook} from "../interfaces/IERC7579Hook.sol";
import {IERC7579Module} from "../interfaces/IERC7579Module.sol";
import {IManagedAccountTimelockHook} from "./IManagedAccountTimelockHook.sol";

uint256 constant MODULE_TYPE_HOOK = 4;

/// @title ManagedAccountTimelockHook
/// @notice ERC-7579 Hook that enforces a timelock on operator operations.
///         Owners bypass the timelock; operators must queue via queueOperation() first.
contract ManagedAccountTimelockHook is IManagedAccountTimelockHook, IERC7579Hook, IERC7579Module {
    // ──────────────────── Storage ────────────────────

    /// @dev Per-account timelock configuration.
    mapping(address account => TimelockConfig) private _configs;

    /// @dev Per-account queue of pending operations.
    mapping(address account => mapping(bytes32 execHash => QueueEntry)) private _queue;

    /// @dev Per-account immediate selector whitelist: account => keccak256(target, selector) => bool.
    mapping(address account => mapping(bytes32 key => bool)) private _immediateSelectors;

    /// @dev Per-account owner address (set during onInstall).
    mapping(address account => address owner) private _owners;

    /// @dev Per-account generation counter, incremented on each install. Included in exec hash
    ///      to invalidate stale queue entries after uninstall/reinstall cycles. [H-02]
    mapping(address account => uint256 generation) private _generations;

    // ──────────────────── Modifiers ────────────────────

    /// @dev Restricts to callers that have been initialized as accounts (have an owner set).
    modifier onlyAccount() {
        if (_owners[msg.sender] == address(0)) revert OnlyAccount();
        _;
    }

    // ──────────────────── ERC-7579 Module Lifecycle ────────────────────

    /// @inheritdoc IERC7579Module
    function onInstall(bytes calldata data) external override(IERC7579Module) {
        // [H-01] Prevent re-installation without first uninstalling.
        if (_owners[msg.sender] != address(0)) revert AlreadyInstalled();

        (address owner, uint128 cooldown, uint128 expiration) = abi.decode(data, (address, uint128, uint128));

        // [L-05 / H-01] Validate parameters.
        if (owner == address(0)) revert InvalidOwner();
        if (cooldown == 0 || expiration == 0) revert InvalidConfig();

        // [M-04] Validate uint48 bounds to prevent silent truncation.
        if (cooldown > type(uint48).max) revert ConfigExceedsUint48Bounds();
        if (expiration > type(uint48).max) revert ConfigExceedsUint48Bounds();

        address account = msg.sender;

        // [H-02] Increment generation to invalidate all stale queue entries from prior installs.
        _generations[account]++;

        _owners[account] = owner;
        _configs[account] = TimelockConfig(cooldown, expiration);
        emit TimelockConfigured(account, cooldown, expiration);
    }

    /// @inheritdoc IERC7579Module
    function onUninstall(bytes calldata) external override(IERC7579Module) {
        address account = msg.sender;
        delete _owners[account];
        delete _configs[account];
        // Note: _queue and _immediateSelectors are NOT cleared in storage, but stale queue entries
        // are invalidated by the generation counter [H-02]. Immediate selectors will not match
        // because preCheck requires initialization.
    }

    /// @inheritdoc IERC7579Module
    function isModuleType(uint256 moduleTypeId) external pure override(IERC7579Module) returns (bool) {
        return moduleTypeId == MODULE_TYPE_HOOK;
    }

    // ──────────────────── Queue Operation ────────────────────

    /// @inheritdoc IManagedAccountTimelockHook
    function queueOperation(
        address account,
        address operator,
        uint256 msgValue,
        bytes calldata msgData
    ) external {
        if (_owners[account] == address(0)) revert NotInitialized();

        // [C-02] Only the operator or the account itself can queue.
        if (msg.sender != operator && msg.sender != account) revert Unauthorized();

        bytes32 execHash = _computeExecHash(account, operator, msgValue, msgData);
        QueueEntry storage entry = _queue[account][execHash];
        if (entry.exists) revert AlreadyQueued(execHash);

        TimelockConfig memory config = _configs[account];
        uint48 now_ = uint48(block.timestamp);
        uint48 executeAfter = now_ + uint48(config.cooldownPeriod);
        uint48 expiresAt = executeAfter + uint48(config.expirationPeriod);

        entry.queuedAt = now_;
        entry.executeAfter = executeAfter;
        entry.expiresAt = expiresAt;
        entry.operator = operator;
        entry.exists = true;

        emit OperationQueued(account, execHash, operator, executeAfter, expiresAt);
    }

    // ──────────────────── IERC7579Hook ────────────────────

    /// @inheritdoc IERC7579Hook
    function preCheck(
        address msgSender,
        uint256 msgValue,
        bytes calldata msgData
    ) external override(IERC7579Hook) returns (bytes memory hookData) {
        address account = msg.sender;

        // [H-05] Reject calls for uninitialized accounts.
        if (_owners[account] == address(0)) revert NotInitialized();

        address owner = _owners[account];

        // Owner bypass: instant execution, no queuing
        if (msgSender == owner) {
            return abi.encode(true, bytes32(0));
        }

        // [C-03] Check immediate selector bypass -- extract target from ERC-7579 execute() calldata.
        // ERC-7579 single execution: execute(bytes32 mode, bytes executionCalldata)
        // executionCalldata = abi.encodePacked(target, value, callData)
        // msgData layout: [4-byte selector][32-byte mode][...executionCalldata...]
        // We decode target (first 20 bytes of executionCalldata) and the inner calldata selector.
        if (msgData.length >= 4 + 32 + 20) {
            // Extract execution mode to ensure single execution
            bytes32 mode = bytes32(msgData[4:36]);
            // ERC-7579 CALLTYPE_SINGLE = 0x00 (first byte of mode)
            // We only allow immediate bypass for single execution (callType == 0x00)
            if (bytes1(mode) == 0x00) {
                // executionCalldata starts at offset 36 (4 selector + 32 mode)
                // target = first 20 bytes of executionCalldata
                address target = address(bytes20(msgData[36:56]));

                // Inner calldata starts at offset 36 + 20 (target) + 32 (value) = 88
                if (msgData.length >= 88 + 4) {
                    bytes4 innerSelector = bytes4(msgData[88:92]);
                    bytes32 selectorKey = keccak256(abi.encodePacked(target, innerSelector));
                    if (_immediateSelectors[account][selectorKey]) {
                        return abi.encode(true, bytes32(0));
                    }
                }
            }
            // For batch mode or unrecognized modes, do NOT allow immediate bypass.
        }

        // Operator path: validate queued operation
        bytes32 execHash = _computeExecHash(account, msgSender, msgValue, msgData);
        QueueEntry storage entry = _queue[account][execHash];

        if (!entry.exists) {
            revert OperationNotQueued(execHash);
        }

        // [M-05] Verify the actual caller is the operator who queued.
        if (entry.operator != msgSender) revert UnauthorizedOperator(msgSender, entry.operator);

        if (block.timestamp > entry.expiresAt) {
            uint48 expiresAt = entry.expiresAt;
            delete _queue[account][execHash];
            revert OperationExpired(execHash, expiresAt);
        }

        if (block.timestamp < entry.executeAfter) {
            revert CooldownNotElapsed(execHash, entry.executeAfter);
        }

        // [H-06] Do NOT delete queue entry here. Pass execHash through hookData so
        // postCheck can delete it after successful execution.
        emit OperationExecuted(account, execHash, msgSender);

        return abi.encode(false, execHash);
    }

    /// @inheritdoc IERC7579Hook
    function postCheck(bytes calldata hookData) external override(IERC7579Hook) {
        (bool isOwnerOrImmediate, bytes32 execHash) = abi.decode(hookData, (bool, bytes32));
        if (isOwnerOrImmediate) return;

        // [H-06] Delete the queue entry only after successful execution.
        if (execHash != bytes32(0)) {
            address account = msg.sender;
            delete _queue[account][execHash];
        }
    }

    // ──────────────────── Admin Functions ────────────────────

    /// @inheritdoc IManagedAccountTimelockHook
    function cancelExecution(bytes32 execHash) external onlyAccount {
        address account = msg.sender;
        QueueEntry storage entry = _queue[account][execHash];
        if (!entry.exists) revert OperationNotQueued(execHash);

        delete _queue[account][execHash];
        emit OperationCancelled(account, execHash);
    }

    /// @inheritdoc IManagedAccountTimelockHook
    function setTimelockConfig(uint128 cooldownPeriod, uint128 expirationPeriod) external onlyAccount {
        if (cooldownPeriod == 0 || expirationPeriod == 0) revert InvalidConfig();

        // [M-04] Validate uint48 bounds.
        if (cooldownPeriod > type(uint48).max) revert ConfigExceedsUint48Bounds();
        if (expirationPeriod > type(uint48).max) revert ConfigExceedsUint48Bounds();

        address account = msg.sender;
        _configs[account] = TimelockConfig(cooldownPeriod, expirationPeriod);
        emit TimelockConfigured(account, cooldownPeriod, expirationPeriod);
    }

    /// @inheritdoc IManagedAccountTimelockHook
    function setImmediateSelector(address target, bytes4 selector, bool immediate) external onlyAccount {
        address account = msg.sender;
        bytes32 key = keccak256(abi.encodePacked(target, selector));
        _immediateSelectors[account][key] = immediate;
        emit SelectorWhitelisted(account, target, selector, immediate);
    }

    // ──────────────────── View Functions ────────────────────

    /// @inheritdoc IManagedAccountTimelockHook
    function getQueueEntry(
        address account,
        bytes32 execHash
    ) external view returns (QueueEntry memory) {
        return _queue[account][execHash];
    }

    /// @inheritdoc IManagedAccountTimelockHook
    function getTimelockConfig(address account) external view returns (TimelockConfig memory) {
        return _configs[account];
    }

    /// @inheritdoc IManagedAccountTimelockHook
    function isImmediateSelector(
        address account,
        address target,
        bytes4 selector
    ) external view returns (bool) {
        bytes32 key = keccak256(abi.encodePacked(target, selector));
        return _immediateSelectors[account][key];
    }

    /// @inheritdoc IManagedAccountTimelockHook
    function computeExecHash(
        address account,
        address msgSender,
        uint256 msgValue,
        bytes calldata msgData
    ) external view returns (bytes32) {
        return _computeExecHash(account, msgSender, msgValue, msgData);
    }

    /// @notice Returns the current generation counter for an account.
    function getGeneration(address account) external view returns (uint256) {
        return _generations[account];
    }

    // ──────────────────── Internal ────────────────────

    function _computeExecHash(
        address account,
        address msgSender,
        uint256 msgValue,
        bytes calldata msgData
    ) internal view returns (bytes32) {
        // [H-04] Include block.chainid and [H-02] generation counter.
        return keccak256(abi.encode(block.chainid, _generations[account], account, msgSender, msgValue, msgData));
    }
}
