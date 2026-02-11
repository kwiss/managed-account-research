// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IERC7579Account
/// @notice Interface for ERC-7579 modular smart accounts
interface IERC7579Account {
    /// @notice Executes a single or batched transaction
    /// @param mode Execution mode encoding (single, batch, delegatecall, etc.)
    /// @param executionCalldata Encoded execution data
    function execute(bytes32 mode, bytes calldata executionCalldata) external;

    /// @notice Executes a transaction on behalf of the account, triggered by an executor module
    /// @param mode Execution mode encoding
    /// @param executionCalldata Encoded execution data
    /// @return returnData Array of return data from each execution
    function executeFromExecutor(bytes32 mode, bytes calldata executionCalldata)
        external
        returns (bytes[] memory returnData);

    /// @notice Installs a module on the account
    /// @param moduleTypeId The type of module (1=Validator, 2=Executor, 3=Fallback, 4=Hook)
    /// @param module The module address
    /// @param initData Initialization data for the module
    function installModule(uint256 moduleTypeId, address module, bytes calldata initData) external;

    /// @notice Uninstalls a module from the account
    /// @param moduleTypeId The type of module
    /// @param module The module address
    /// @param deInitData De-initialization data for the module
    function uninstallModule(uint256 moduleTypeId, address module, bytes calldata deInitData) external;

    /// @notice Checks if a module is installed on the account
    /// @param moduleTypeId The type of module
    /// @param module The module address
    /// @param additionalContext Additional context for the check
    /// @return True if the module is installed
    function isModuleInstalled(uint256 moduleTypeId, address module, bytes calldata additionalContext)
        external
        view
        returns (bool);
}
