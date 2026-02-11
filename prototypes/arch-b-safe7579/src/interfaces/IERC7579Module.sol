// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IModule
/// @notice Base interface for all ERC-7579 modules
interface IModule {
    /// @notice Called when the module is installed on an account
    /// @param data Initialization data
    function onInstall(bytes calldata data) external;

    /// @notice Called when the module is uninstalled from an account
    /// @param data De-initialization data
    function onUninstall(bytes calldata data) external;

    /// @notice Returns whether the module is of a certain type
    /// @param moduleTypeId The module type ID to check
    /// @return True if the module is of the given type
    function isModuleType(uint256 moduleTypeId) external view returns (bool);
}

/// @title IValidator
/// @notice Interface for ERC-7579 Validator modules (type 1)
/// @dev Validates UserOperation signatures and ERC-1271 signatures
interface IValidator is IModule {
    /// @notice Validates a UserOperation
    /// @param userOp Packed UserOperation data
    /// @param userOpHash Hash of the UserOperation
    /// @return validationData Packed validation data (aggregator, validAfter, validUntil)
    function validateUserOp(bytes calldata userOp, bytes32 userOpHash) external returns (uint256 validationData);

    /// @notice Validates an ERC-1271 signature
    /// @param hash The hash to validate
    /// @param data The signature data
    /// @return magicValue The ERC-1271 magic value if valid
    function isValidSignatureWithSender(address sender, bytes32 hash, bytes calldata data)
        external
        view
        returns (bytes4 magicValue);
}

/// @title IExecutor
/// @notice Interface for ERC-7579 Executor modules (type 2)
/// @dev Can trigger executions on the account via executeFromExecutor
interface IExecutor is IModule {}

/// @title IFallback
/// @notice Interface for ERC-7579 Fallback modules (type 3)
/// @dev Handles calls to the account that don't match any function selector
interface IFallback is IModule {}
