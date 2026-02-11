// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ModuleType
/// @notice Constants for ERC-7579 module types

/// @dev Validator modules validate UserOperations and signatures
uint256 constant MODULE_TYPE_VALIDATOR = 1;

/// @dev Executor modules can trigger executions on the account
uint256 constant MODULE_TYPE_EXECUTOR = 2;

/// @dev Fallback modules handle calls to undefined selectors
uint256 constant MODULE_TYPE_FALLBACK = 3;

/// @dev Hook modules intercept executions for pre/post checks
uint256 constant MODULE_TYPE_HOOK = 4;
