// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IModule} from "./IERC7579Module.sol";

/// @title IERC7579Hook
/// @notice Interface for ERC-7579 Hook modules (type 4)
/// @dev Hooks intercept executions before and after they occur
interface IERC7579Hook is IModule {
    /// @notice Called before an execution on the account
    /// @param msgSender The address that triggered the execution
    /// @param msgValue The ETH value sent with the execution
    /// @param msgData The calldata of the execution
    /// @return hookData Arbitrary data to pass to postCheck
    function preCheck(address msgSender, uint256 msgValue, bytes calldata msgData)
        external
        returns (bytes memory hookData);

    /// @notice Called after an execution on the account
    /// @param hookData Data returned from preCheck
    function postCheck(bytes calldata hookData) external;
}
