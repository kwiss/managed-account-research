// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IERC7579Account - Minimal ERC-7579 smart account interface.
interface IERC7579Account {
    /// @notice Executes a single operation from the account.
    /// @param mode The execution mode (single, batch, delegatecall, etc.).
    /// @param executionCalldata The encoded execution data.
    function execute(bytes32 mode, bytes calldata executionCalldata) external payable;

    /// @notice Executes an operation from an installed executor module.
    /// @param mode The execution mode.
    /// @param executionCalldata The encoded execution data.
    /// @return returnData The return data from the execution.
    function executeFromExecutor(
        bytes32 mode,
        bytes calldata executionCalldata
    ) external payable returns (bytes[] memory returnData);

    /// @notice Installs a module on the account.
    /// @param moduleTypeId The type of module (validator, executor, hook, fallback).
    /// @param module The address of the module to install.
    /// @param initData Initialization data for the module.
    function installModule(
        uint256 moduleTypeId,
        address module,
        bytes calldata initData
    ) external;

    /// @notice Uninstalls a module from the account.
    /// @param moduleTypeId The type of module.
    /// @param module The address of the module to uninstall.
    /// @param deInitData De-initialization data for the module.
    function uninstallModule(
        uint256 moduleTypeId,
        address module,
        bytes calldata deInitData
    ) external;

    /// @notice Checks if a module is installed on the account.
    /// @param moduleTypeId The type of module.
    /// @param module The address of the module.
    /// @param additionalContext Additional context for the check.
    /// @return True if the module is installed.
    function isModuleInstalled(
        uint256 moduleTypeId,
        address module,
        bytes calldata additionalContext
    ) external view returns (bool);
}
