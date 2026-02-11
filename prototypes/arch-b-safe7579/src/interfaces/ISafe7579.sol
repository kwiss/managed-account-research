// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ISafe7579
/// @notice Interface for the Safe7579 Adapter that bridges Safe to ERC-7579 module ecosystem
interface ISafe7579 {
    /// @notice Initializes the Safe7579 adapter on a Safe account
    /// @param data Encoded initialization parameters (validators, executors, fallbacks, hooks)
    function initializeAccount(bytes calldata data) external;

    /// @notice Installs a module via the Safe7579 adapter
    /// @param moduleTypeId The type of module (1=Validator, 2=Executor, 3=Fallback, 4=Hook)
    /// @param module The module address
    /// @param initData Module initialization data
    function installModule(uint256 moduleTypeId, address module, bytes calldata initData) external;

    /// @notice Uninstalls a module via the Safe7579 adapter
    /// @param moduleTypeId The type of module
    /// @param module The module address
    /// @param deInitData Module de-initialization data
    function uninstallModule(uint256 moduleTypeId, address module, bytes calldata deInitData) external;
}
