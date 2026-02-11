// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ISafe
/// @notice Interface for Gnosis Safe core functionality
interface ISafe {
    /// @notice Execute a transaction from an enabled module
    /// @param to Destination address
    /// @param value ETH value
    /// @param data Call data
    /// @param operation Operation type (0 = Call, 1 = DelegateCall)
    /// @return success Whether the transaction was successful
    function execTransactionFromModule(address to, uint256 value, bytes memory data, uint8 operation)
        external
        returns (bool success);

    /// @notice Enable a module on the Safe
    /// @param module Module address to enable
    function enableModule(address module) external;

    /// @notice Disable a module on the Safe
    /// @param prevModule Previous module in the linked list
    /// @param module Module address to disable
    function disableModule(address prevModule, address module) external;

    /// @notice Set the fallback handler for the Safe
    /// @param handler Fallback handler address
    function setFallbackHandler(address handler) external;

    /// @notice Returns the list of Safe owners
    /// @return Array of owner addresses
    function getOwners() external view returns (address[] memory);

    /// @notice Returns the threshold of the Safe
    /// @return Threshold number
    function getThreshold() external view returns (uint256);

    /// @notice Checks if an address is a Safe owner
    /// @param owner Address to check
    /// @return True if the address is an owner
    function isOwner(address owner) external view returns (bool);
}
