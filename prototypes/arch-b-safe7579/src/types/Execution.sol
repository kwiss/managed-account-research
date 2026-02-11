// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Execution
/// @notice Struct representing a single execution call in ERC-7579
struct Execution {
    /// @dev Target contract address
    address target;
    /// @dev ETH value to send
    uint256 value;
    /// @dev Calldata for the call
    bytes callData;
}
