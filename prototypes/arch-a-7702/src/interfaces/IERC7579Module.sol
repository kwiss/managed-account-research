// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IERC7579Module - Base interface for all ERC-7579 modules.
interface IERC7579Module {
    /// @notice Called when the module is installed on an account.
    /// @param data Initialization data.
    function onInstall(bytes calldata data) external;

    /// @notice Called when the module is uninstalled from an account.
    /// @param data De-initialization data.
    function onUninstall(bytes calldata data) external;

    /// @notice Returns whether the module matches a given module type.
    /// @param moduleTypeId The module type to check.
    /// @return True if the module is of the given type.
    function isModuleType(uint256 moduleTypeId) external view returns (bool);
}

/// @title IValidator - ERC-7579 Validator module interface.
interface IValidator is IERC7579Module {
    /// @notice Validates a user operation.
    /// @param userOpHash The hash of the user operation.
    /// @param signature The signature to validate.
    /// @return validationData Packed validation data (sigFailed, validUntil, validAfter).
    function validateUserOp(
        bytes32 userOpHash,
        bytes calldata signature
    ) external returns (uint256 validationData);
}

/// @title IExecutor - ERC-7579 Executor module interface.
interface IExecutor is IERC7579Module {}

/// @title IHook - ERC-7579 Hook module interface (re-exports IERC7579Hook).
interface IHook is IERC7579Module {
    function preCheck(
        address msgSender,
        uint256 msgValue,
        bytes calldata msgData
    ) external returns (bytes memory hookData);

    function postCheck(bytes calldata hookData) external;
}

/// @title IFallback - ERC-7579 Fallback module interface.
interface IFallback is IERC7579Module {}
