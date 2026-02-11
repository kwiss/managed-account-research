// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC7579Hook} from "../interfaces/IERC7579Hook.sol";
import {IERC7579Module} from "../interfaces/IERC7579Module.sol";

uint256 constant MODULE_TYPE_HOOK = 4;

/// @title HookMultiPlexer
/// @notice Composes multiple ERC-7579 hooks into a single hook.
///         preCheck iterates sub-hooks forward, postCheck iterates in reverse.
///
/// @dev WARNING [H-03]: When this multiplexer calls sub-hooks, `msg.sender` for the sub-hook
///      is the HookMultiPlexer address, NOT the original account. This means any sub-hook that
///      uses `msg.sender` to identify the account (e.g., ManagedAccountTimelockHook) will NOT
///      work correctly when composed through this multiplexer. Do NOT use this multiplexer with
///      ManagedAccountTimelockHook. They are fundamentally incompatible in the current design.
///      A future redesign could pass the account address explicitly or use delegatecall.
contract HookMultiPlexer is IERC7579Hook, IERC7579Module {
    // ──────────────────── Errors ────────────────────

    error OnlyAccount();
    error HookAlreadyAdded(address hook);
    error HookNotFound(address hook);

    // ──────────────────── Events ────────────────────

    event HookAdded(address indexed account, address indexed hook);
    event HookRemoved(address indexed account, address indexed hook);

    // ──────────────────── Storage ────────────────────

    /// @dev Per-account list of sub-hooks.
    mapping(address account => address[]) private _hooks;

    /// @dev Fast lookup for whether a hook is installed for an account.
    mapping(address account => mapping(address hook => bool)) private _hookExists;

    // ──────────────────── ERC-7579 Module Lifecycle ────────────────────

    /// @inheritdoc IERC7579Module
    function onInstall(bytes calldata data) external override(IERC7579Module) {
        if (data.length > 0) {
            address[] memory hooks = abi.decode(data, (address[]));
            address account = msg.sender;
            for (uint256 i; i < hooks.length; ++i) {
                _addHook(account, hooks[i]);
            }
        }
    }

    /// @inheritdoc IERC7579Module
    function onUninstall(bytes calldata) external override(IERC7579Module) {
        address account = msg.sender;
        address[] storage hooks = _hooks[account];
        for (uint256 i; i < hooks.length; ++i) {
            _hookExists[account][hooks[i]] = false;
        }
        delete _hooks[account];
    }

    /// @inheritdoc IERC7579Module
    function isModuleType(uint256 moduleTypeId) external pure override(IERC7579Module) returns (bool) {
        return moduleTypeId == MODULE_TYPE_HOOK;
    }

    // ──────────────────── IERC7579Hook ────────────────────

    /// @inheritdoc IERC7579Hook
    function preCheck(
        address msgSender,
        uint256 msgValue,
        bytes calldata msgData
    ) external override(IERC7579Hook) returns (bytes memory hookData) {
        address account = msg.sender;
        address[] storage hooks = _hooks[account];
        uint256 len = hooks.length;

        // Collect hookData from each sub-hook
        bytes[] memory allHookData = new bytes[](len);
        for (uint256 i; i < len; ++i) {
            allHookData[i] = IERC7579Hook(hooks[i]).preCheck(msgSender, msgValue, msgData);
        }

        return abi.encode(allHookData);
    }

    /// @inheritdoc IERC7579Hook
    function postCheck(bytes calldata hookData) external override(IERC7579Hook) {
        address account = msg.sender;
        address[] storage hooks = _hooks[account];
        uint256 len = hooks.length;

        bytes[] memory allHookData = abi.decode(hookData, (bytes[]));

        // Call postCheck in reverse order
        for (uint256 i = len; i > 0; --i) {
            IERC7579Hook(hooks[i - 1]).postCheck(allHookData[i - 1]);
        }
    }

    // ──────────────────── Hook Management ────────────────────

    /// @notice Adds a sub-hook for the calling account.
    function addHook(address hook) external {
        _addHook(msg.sender, hook);
    }

    /// @notice Removes a sub-hook for the calling account.
    function removeHook(address hook) external {
        address account = msg.sender;
        if (!_hookExists[account][hook]) revert HookNotFound(hook);

        _hookExists[account][hook] = false;

        // Find and remove from array (swap-and-pop)
        address[] storage hooks = _hooks[account];
        uint256 len = hooks.length;
        for (uint256 i; i < len; ++i) {
            if (hooks[i] == hook) {
                hooks[i] = hooks[len - 1];
                hooks.pop();
                break;
            }
        }

        emit HookRemoved(account, hook);
    }

    // ──────────────────── View Functions ────────────────────

    /// @notice Returns the list of sub-hooks for an account.
    function getHooks(address account) external view returns (address[] memory) {
        return _hooks[account];
    }

    // ──────────────────── Internal ────────────────────

    function _addHook(address account, address hook) internal {
        if (_hookExists[account][hook]) revert HookAlreadyAdded(hook);
        _hooks[account].push(hook);
        _hookExists[account][hook] = true;
        emit HookAdded(account, hook);
    }
}
