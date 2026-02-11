// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IActionPolicy} from "../interfaces/IActionPolicy.sol";

/// @title AaveSupplyPolicy
/// @notice Policy contract that validates Aave V3 supply parameters
/// @dev Checks: allowed asset, recipient (onBehalfOf), and daily supply volume limits
///
/// Validates calls to Aave V3 Pool's supply:
///   function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode)
contract AaveSupplyPolicy is IActionPolicy {
    // ─── Structs ─────────────────────────────────────────────────────────────

    /// @notice Configuration for allowed supply parameters per account+target
    struct SupplyConfig {
        /// @dev Allowed asset to supply (address(0) = any)
        address asset;
        /// @dev Required onBehalfOf address (address(0) = any, typically must be the Safe itself)
        address onBehalfOf;
        /// @dev Maximum daily supply volume in asset wei (0 = unlimited)
        uint256 maxDailyVolume;
        /// @dev Whether this config is active
        bool active;
    }

    /// @notice Daily volume tracking
    struct DailyVolume {
        uint256 day;
        uint256 consumed;
    }

    // ─── Storage ─────────────────────────────────────────────────────────────

    /// @dev account => target => SupplyConfig
    mapping(address => mapping(address => SupplyConfig)) private _configs;

    /// @dev account => target => DailyVolume
    mapping(address => mapping(address => DailyVolume)) private _dailyVolumes;

    // ─── Events ──────────────────────────────────────────────────────────────

    event SupplyConfigSet(address indexed account, address indexed target, SupplyConfig config);

    // ─── Errors ──────────────────────────────────────────────────────────────

    error PolicyNotConfigured(address account, address target);
    error InvalidAsset(address provided, address expected);
    error InvalidOnBehalfOf(address provided, address expected);
    error DailyVolumeLimitExceeded(uint256 consumed, uint256 limit);
    error InvalidCalldata();
    error UnauthorizedCaller();

    // ─── Configuration ───────────────────────────────────────────────────────

    /// @notice Set supply policy configuration for a target
    /// @param target The Aave pool address
    /// @param config The supply configuration
    function setSupplyConfig(address target, SupplyConfig calldata config) external {
        _configs[msg.sender][target] = config;
        emit SupplyConfigSet(msg.sender, target, config);
    }

    /// @notice Get supply policy configuration
    function getSupplyConfig(address account, address target) external view returns (SupplyConfig memory) {
        return _configs[account][target];
    }

    // ─── IActionPolicy ───────────────────────────────────────────────────────

    /// @inheritdoc IActionPolicy
    function checkAction(address account, address target, uint256, bytes calldata callData)
        external
        override
        returns (bool)
    {
        // H-01: Only the account itself (or SmartSession acting through the account) can call checkAction
        if (msg.sender != account) revert UnauthorizedCaller();

        SupplyConfig storage config = _configs[account][target];
        if (!config.active) revert PolicyNotConfigured(account, target);

        // Minimum calldata: 4 (selector) + 4*32 (4 params) = 132 bytes
        if (callData.length < 132) revert InvalidCalldata();

        // Decode supply params:
        //   [4:36]   = asset (address)
        //   [36:68]  = amount (uint256)
        //   [68:100] = onBehalfOf (address)
        address asset = address(uint160(uint256(bytes32(callData[4:36]))));
        uint256 amount = uint256(bytes32(callData[36:68]));
        address onBehalfOf = address(uint160(uint256(bytes32(callData[68:100]))));

        // Validate asset
        if (config.asset != address(0) && asset != config.asset) {
            revert InvalidAsset(asset, config.asset);
        }

        // Validate onBehalfOf
        if (config.onBehalfOf != address(0) && onBehalfOf != config.onBehalfOf) {
            revert InvalidOnBehalfOf(onBehalfOf, config.onBehalfOf);
        }

        // Validate daily volume
        if (config.maxDailyVolume > 0) {
            DailyVolume storage vol = _dailyVolumes[account][target];
            uint256 currentDay = block.timestamp / 1 days;

            if (vol.day != currentDay) {
                vol.day = currentDay;
                vol.consumed = 0;
            }

            uint256 newConsumed = vol.consumed + amount;
            if (newConsumed > config.maxDailyVolume) {
                revert DailyVolumeLimitExceeded(newConsumed, config.maxDailyVolume);
            }

            vol.consumed = newConsumed;
        }

        return true;
    }
}
