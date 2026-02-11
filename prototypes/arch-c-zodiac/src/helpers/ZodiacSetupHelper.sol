// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISafe} from "../interfaces/ISafe.sol";
import {IDelay} from "../interfaces/IDelay.sol";
import {ISafe4337RolesModule} from "../interfaces/ISafe4337RolesModule.sol";

/// @title ZodiacSetupHelper
/// @notice Helper contract to configure the full Zodiac module chain in one call
/// @dev Intended for use in deployment scripts, not as an on-chain factory.
/// Configures: Safe -> Roles -> Delay -> Safe4337RolesModule -> operators
contract ZodiacSetupHelper {
    /// @notice Parameters for setting up the full Zodiac module chain
    /// @param safe The Safe multi-sig address
    /// @param rolesModule The Zodiac Roles v2 module address
    /// @param delayModule The Zodiac Delay module address
    /// @param safe4337RolesModule The custom bridge module address
    /// @param operators Array of operator addresses to register
    /// @param roleKeys Array of role keys corresponding to each operator
    /// @param validUntils Array of validUntil timestamps corresponding to each operator
    /// @param timelockCooldown Delay module cooldown in seconds
    /// @param timelockExpiration Delay module expiration in seconds
    struct SetupParams {
        address safe;
        address rolesModule;
        address delayModule;
        address safe4337RolesModule;
        address[] operators;
        uint16[] roleKeys;
        uint48[] validUntils;
        uint256 timelockCooldown;
        uint256 timelockExpiration;
    }

    error ArrayLengthMismatch();

    /// @notice Configure the full Zodiac module chain
    /// @dev Must be called by the Safe (via execTransaction) since enableModule is restricted
    /// @param params The setup parameters
    function setup(SetupParams calldata params) external {
        if (params.operators.length != params.roleKeys.length) revert ArrayLengthMismatch();
        if (params.operators.length != params.validUntils.length) revert ArrayLengthMismatch();

        ISafe safe = ISafe(params.safe);

        // 1. Enable Roles module on Safe
        safe.enableModule(params.rolesModule);

        // 2. Enable Delay module on Safe
        safe.enableModule(params.delayModule);

        // 3. Enable Safe4337RolesModule on Safe
        safe.enableModule(params.safe4337RolesModule);

        // 4. Configure Delay cooldown/expiration
        IDelay delay = IDelay(params.delayModule);
        delay.setTxCooldown(params.timelockCooldown);
        delay.setTxExpiration(params.timelockExpiration);

        // 5. Register operators with their role keys and validUntil
        ISafe4337RolesModule bridgeModule = ISafe4337RolesModule(params.safe4337RolesModule);
        for (uint256 i = 0; i < params.operators.length; i++) {
            bridgeModule.addOperator(params.operators[i], params.roleKeys[i], params.validUntils[i]);
        }
    }
}
