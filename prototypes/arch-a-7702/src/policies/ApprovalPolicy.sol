// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IActionPolicy} from "../interfaces/IActionPolicy.sol";

/// @title ApprovalPolicy
/// @notice Validates ERC-20 approve(address,uint256) calls to prevent unlimited approvals to unknown spenders.
contract ApprovalPolicy is IActionPolicy {
    // ──────────────────── Structs ────────────────────

    struct ApprovalConfig {
        address[] allowedSpenders;
        uint256 maxApproval;
    }

    // ──────────────────── Errors ────────────────────

    error SpenderNotAllowed(address spender);
    error ExceedsMaxApproval(uint256 amount, uint256 max);
    error NoEthValueAllowed();
    error NotInitialized(address account);
    error InvalidCalldata();
    error OnlyAccount();
    error AlreadyInitialized(address account);

    // ──────────────────── Events ────────────────────

    event PolicyInitialized(address indexed account);

    // ──────────────────── Storage ────────────────────

    mapping(address account => ApprovalConfig) private _configs;
    mapping(address account => bool) private _initialized;

    // ──────────────────── Initialization ────────────────────

    /// @notice Initializes the policy for a given account.
    /// @dev Only callable by the account itself. Cannot be called if already initialized. [C-01]
    function initializePolicy(address account, ApprovalConfig calldata config) external {
        if (msg.sender != account) revert OnlyAccount();
        if (_initialized[account]) revert AlreadyInitialized(account);
        _configs[account] = config;
        _initialized[account] = true;
        emit PolicyInitialized(account);
    }

    // ──────────────────── IActionPolicy ────────────────────

    // ERC-20 approve(address,uint256) selector = 0x095ea7b3
    // Layout after selector: spender (32 bytes) + amount (32 bytes) = 68 bytes total

    /// @inheritdoc IActionPolicy
    function checkAction(
        bytes32,
        address account,
        address,
        uint256 value,
        bytes calldata data
    ) external override returns (uint256) {
        if (!_initialized[account]) revert NotInitialized(account);
        if (value != 0) revert NoEthValueAllowed();
        if (data.length < 68) revert InvalidCalldata();

        // Decode approve(address spender, uint256 amount)
        bytes calldata params = data[4:];
        address spender = address(bytes20(params[12:32]));
        uint256 amount = uint256(bytes32(params[32:64]));

        ApprovalConfig storage config = _configs[account];

        if (!_isInArray(spender, config.allowedSpenders)) {
            revert SpenderNotAllowed(spender);
        }
        if (amount > config.maxApproval) {
            revert ExceedsMaxApproval(amount, config.maxApproval);
        }

        return 0;
    }

    // ──────────────────── Internal ────────────────────

    function _isInArray(address value, address[] storage arr) internal view returns (bool) {
        for (uint256 i; i < arr.length; ++i) {
            if (arr[i] == value) return true;
        }
        return false;
    }
}
