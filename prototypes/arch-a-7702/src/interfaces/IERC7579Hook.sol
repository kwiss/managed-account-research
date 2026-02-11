// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC7579Hook {
    /// @notice Called before an execution on the account.
    /// @param msgSender The caller of the account execution.
    /// @param msgValue The ETH value sent with the call.
    /// @param msgData The calldata of the execution.
    /// @return hookData Arbitrary data to be passed to postCheck.
    function preCheck(
        address msgSender,
        uint256 msgValue,
        bytes calldata msgData
    ) external returns (bytes memory hookData);

    /// @notice Called after an execution on the account.
    /// @param hookData The data returned by preCheck.
    function postCheck(bytes calldata hookData) external;
}
