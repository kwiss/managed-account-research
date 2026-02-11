// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ISafe - Gnosis Safe interface for module interactions
/// @notice Minimal interface for Safe operations used by the ManagedAccount system
interface ISafe {
    /// @notice Execute a transaction confirmed by required number of owners
    /// @param to Destination address
    /// @param value Ether value
    /// @param data Data payload
    /// @param operation Operation type (0 = Call, 1 = DelegateCall)
    /// @param safeTxGas Gas for the Safe transaction
    /// @param baseGas Gas costs independent of the transaction execution
    /// @param gasPrice Maximum gas price for this transaction
    /// @param gasToken Token address for gas payment (or 0 for ETH)
    /// @param refundReceiver Address to receive gas refund
    /// @param signatures Packed signature data
    /// @return success Whether the transaction was successful
    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes calldata signatures
    ) external payable returns (bool success);

    /// @notice Execute a transaction from an enabled module
    /// @param to Destination address
    /// @param value Ether value
    /// @param data Data payload
    /// @param operation Operation type (0 = Call, 1 = DelegateCall)
    /// @return success Whether the transaction was successful
    function execTransactionFromModule(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation
    ) external returns (bool success);

    /// @notice Enable a module on the Safe
    /// @param module Module to enable
    function enableModule(address module) external;

    /// @notice Disable a module on the Safe
    /// @param prevModule Module that pointed to the module to disable in the linked list
    /// @param module Module to disable
    function disableModule(address prevModule, address module) external;

    /// @notice Returns the list of Safe owners
    /// @return Array of owner addresses
    function getOwners() external view returns (address[] memory);

    /// @notice Check if an address is a Safe owner
    /// @param owner Address to check
    /// @return Whether the address is an owner
    function isOwner(address owner) external view returns (bool);

    /// @notice Returns the Safe threshold
    /// @return Threshold number
    function getThreshold() external view returns (uint256);

    /// @notice Returns the current nonce of the Safe
    /// @return Safe nonce
    function nonce() external view returns (uint256);
}
