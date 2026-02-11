// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC7579Hook} from "../interfaces/IERC7579Hook.sol";
import {IModule} from "../interfaces/IERC7579Module.sol";
import {MODULE_TYPE_HOOK} from "../types/ModuleType.sol";

/// @title HookMultiPlexer
/// @notice ERC-7579 Hook that composes multiple sub-hooks
/// @dev Manages a per-account ordered list of sub-hooks.
///      preCheck iterates all sub-hooks forward, aggregating hookData.
///      postCheck iterates all sub-hooks in reverse with their respective hookData.
contract HookMultiPlexer is IERC7579Hook {
    // ─── Constants ───────────────────────────────────────────────────────────

    uint256 public constant MAX_HOOKS = 16;

    // ─── Storage ─────────────────────────────────────────────────────────────

    /// @dev account => array of sub-hook addresses
    mapping(address => address[]) private _hooks;

    // ─── Events ──────────────────────────────────────────────────────────────

    event HookAdded(address indexed account, address indexed hook);
    event HookRemoved(address indexed account, address indexed hook);

    // ─── Errors ──────────────────────────────────────────────────────────────

    error HookAlreadyAdded(address hook);
    error HookNotFound(address hook);
    error TooManyHooks();
    error ZeroAddress();
    error HookCountMismatch();

    // ─── ERC-7579 Module Lifecycle ───────────────────────────────────────────

    /// @inheritdoc IModule
    function onInstall(bytes calldata data) external override {
        if (data.length == 0) return;

        // Decode initial hooks to add
        address[] memory initialHooks = abi.decode(data, (address[]));
        for (uint256 i = 0; i < initialHooks.length; i++) {
            _addHook(msg.sender, initialHooks[i]);
        }
    }

    /// @inheritdoc IModule
    function onUninstall(bytes calldata) external override {
        delete _hooks[msg.sender];
    }

    /// @inheritdoc IModule
    function isModuleType(uint256 moduleTypeId) external pure override returns (bool) {
        return moduleTypeId == MODULE_TYPE_HOOK;
    }

    // ─── Hook Logic ──────────────────────────────────────────────────────────

    /// @inheritdoc IERC7579Hook
    function preCheck(address msgSender, uint256 msgValue, bytes calldata msgData)
        external
        override
        returns (bytes memory hookData)
    {
        // H-04: Cache hooks array in memory before iterating to prevent reentrancy manipulation
        address[] memory cachedHooks = _hooks[msg.sender];
        uint256 len = cachedHooks.length;

        if (len == 0) {
            return "";
        }

        // Collect hookData from each sub-hook
        bytes[] memory allHookData = new bytes[](len);
        for (uint256 i = 0; i < len; i++) {
            allHookData[i] = IERC7579Hook(cachedHooks[i]).preCheck(msgSender, msgValue, msgData);
        }

        // Encode all hookData for postCheck
        return abi.encode(allHookData);
    }

    /// @inheritdoc IERC7579Hook
    function postCheck(bytes calldata hookData) external override {
        // H-04: Cache hooks array in memory before iterating
        address[] memory cachedHooks = _hooks[msg.sender];
        uint256 len = cachedHooks.length;

        if (len == 0) return;
        if (hookData.length == 0) return;

        bytes[] memory allHookData = abi.decode(hookData, (bytes[]));

        // M-07: Validate array length consistency
        if (allHookData.length != len) revert HookCountMismatch();

        // Iterate in reverse for postCheck
        for (uint256 i = len; i > 0; i--) {
            IERC7579Hook(cachedHooks[i - 1]).postCheck(allHookData[i - 1]);
        }
    }

    // ─── Management Functions ────────────────────────────────────────────────

    /// @notice Add a sub-hook to the account's hook list
    /// @param hook The sub-hook address to add
    function addHook(address hook) external {
        _addHook(msg.sender, hook);
    }

    /// @notice Remove a sub-hook from the account's hook list
    /// @param hook The sub-hook address to remove
    function removeHook(address hook) external {
        address[] storage hooks = _hooks[msg.sender];
        uint256 len = hooks.length;

        for (uint256 i = 0; i < len; i++) {
            if (hooks[i] == hook) {
                // Swap with last element and pop
                hooks[i] = hooks[len - 1];
                hooks.pop();
                emit HookRemoved(msg.sender, hook);
                return;
            }
        }

        revert HookNotFound(hook);
    }

    // ─── View Functions ──────────────────────────────────────────────────────

    /// @notice Get all sub-hooks for an account
    /// @param account The account address
    /// @return Array of sub-hook addresses
    function getHooks(address account) external view returns (address[] memory) {
        return _hooks[account];
    }

    /// @notice Get the number of sub-hooks for an account
    /// @param account The account address
    /// @return Number of sub-hooks
    function getHookCount(address account) external view returns (uint256) {
        return _hooks[account].length;
    }

    // ─── Internal ────────────────────────────────────────────────────────────

    function _addHook(address account, address hook) internal {
        if (hook == address(0)) revert ZeroAddress();

        address[] storage hooks = _hooks[account];

        // Check for duplicates
        for (uint256 i = 0; i < hooks.length; i++) {
            if (hooks[i] == hook) revert HookAlreadyAdded(hook);
        }

        if (hooks.length >= MAX_HOOKS) revert TooManyHooks();

        hooks.push(hook);
        emit HookAdded(account, hook);
    }
}
