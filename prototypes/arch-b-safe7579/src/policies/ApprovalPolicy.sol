// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IActionPolicy} from "../interfaces/IActionPolicy.sol";

/// @title ApprovalPolicy
/// @notice Policy contract that validates ERC-20 approve() calls
/// @dev Ensures operators can only approve whitelisted spenders up to configured limits
///
/// Validates calls to ERC-20's approve:
///   function approve(address spender, uint256 amount) returns (bool)
contract ApprovalPolicy is IActionPolicy {
    // ─── Structs ─────────────────────────────────────────────────────────────

    /// @notice Configuration for allowed approval parameters per account+target (token)
    struct ApprovalConfig {
        /// @dev Allowed spender (address(0) = any, but typically a specific DeFi protocol)
        address spender;
        /// @dev Maximum approval amount (0 = unlimited)
        uint256 maxAmount;
        /// @dev Whether this config is active
        bool active;
    }

    // ─── Storage ─────────────────────────────────────────────────────────────

    /// @dev account => target (token) => ApprovalConfig
    mapping(address => mapping(address => ApprovalConfig)) private _configs;

    // ─── Events ──────────────────────────────────────────────────────────────

    event ApprovalConfigSet(address indexed account, address indexed target, ApprovalConfig config);

    // ─── Errors ──────────────────────────────────────────────────────────────

    error PolicyNotConfigured(address account, address target);
    error InvalidSpender(address provided, address expected);
    error AmountExceedsLimit(uint256 provided, uint256 limit);
    error InvalidCalldata();

    // ─── Configuration ───────────────────────────────────────────────────────

    /// @notice Set approval policy configuration for a token
    /// @param target The ERC-20 token address
    /// @param config The approval configuration
    function setApprovalConfig(address target, ApprovalConfig calldata config) external {
        _configs[msg.sender][target] = config;
        emit ApprovalConfigSet(msg.sender, target, config);
    }

    /// @notice Get approval policy configuration
    function getApprovalConfig(address account, address target) external view returns (ApprovalConfig memory) {
        return _configs[account][target];
    }

    // ─── IActionPolicy ───────────────────────────────────────────────────────

    /// @inheritdoc IActionPolicy
    function checkAction(address account, address target, uint256, bytes calldata callData)
        external
        view
        override
        returns (bool)
    {
        ApprovalConfig storage config = _configs[account][target];
        if (!config.active) revert PolicyNotConfigured(account, target);

        // Minimum calldata: 4 (selector) + 2*32 (2 params) = 68 bytes
        if (callData.length < 68) revert InvalidCalldata();

        // Decode approve params:
        //   [4:36]  = spender (address)
        //   [36:68] = amount (uint256)
        address spender = address(uint160(uint256(bytes32(callData[4:36]))));
        uint256 amount = uint256(bytes32(callData[36:68]));

        // Validate spender
        if (config.spender != address(0) && spender != config.spender) {
            revert InvalidSpender(spender, config.spender);
        }

        // Validate amount
        if (config.maxAmount > 0 && amount > config.maxAmount) {
            revert AmountExceedsLimit(amount, config.maxAmount);
        }

        return true;
    }
}
