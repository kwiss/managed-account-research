// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IActionPolicy} from "../interfaces/IActionPolicy.sol";

/// @title UniswapSwapPolicy
/// @notice Policy contract that validates Uniswap V3 swap parameters
/// @dev Checks: tokenIn, tokenOut, recipient, fee tier, and daily volume limits
///
/// Validates calls to Uniswap V3 Router's exactInputSingle:
///   function exactInputSingle(ExactInputSingleParams calldata params) returns (uint256 amountOut)
///   struct ExactInputSingleParams {
///       address tokenIn;
///       address tokenOut;
///       uint24 fee;
///       address recipient;
///       uint256 amountIn;
///       uint256 amountOutMinimum;
///       uint160 sqrtPriceLimitX96;
///   }
contract UniswapSwapPolicy is IActionPolicy {
    // ─── Structs ─────────────────────────────────────────────────────────────

    /// @notice Configuration for allowed swap parameters per account+target
    struct SwapConfig {
        /// @dev Allowed input token (address(0) = any)
        address tokenIn;
        /// @dev Allowed output token (address(0) = any)
        address tokenOut;
        /// @dev Required recipient (address(0) = any, but typically must be the Safe itself)
        address recipient;
        /// @dev Allowed fee tier (0 = any, typical values: 500, 3000, 10000)
        uint24 feeTier;
        /// @dev Maximum daily volume in tokenIn wei (0 = unlimited)
        uint256 maxDailyVolume;
        /// @dev Whether this config is active
        bool active;
    }

    /// @notice Daily volume tracking
    struct DailyVolume {
        /// @dev The day number (block.timestamp / 1 days)
        uint256 day;
        /// @dev Volume consumed on that day
        uint256 consumed;
    }

    // ─── Storage ─────────────────────────────────────────────────────────────

    /// @dev account => target => SwapConfig
    mapping(address => mapping(address => SwapConfig)) private _configs;

    /// @dev account => target => DailyVolume
    mapping(address => mapping(address => DailyVolume)) private _dailyVolumes;

    // ─── Events ──────────────────────────────────────────────────────────────

    event SwapConfigSet(address indexed account, address indexed target, SwapConfig config);

    // ─── Errors ──────────────────────────────────────────────────────────────

    error PolicyNotConfigured(address account, address target);
    error InvalidTokenIn(address provided, address expected);
    error InvalidTokenOut(address provided, address expected);
    error InvalidRecipient(address provided, address expected);
    error InvalidFeeTier(uint24 provided, uint24 expected);
    error DailyVolumeLimitExceeded(uint256 consumed, uint256 limit);
    error InvalidCalldata();
    error UnauthorizedCaller();

    // ─── Configuration ───────────────────────────────────────────────────────

    /// @notice Set swap policy configuration for a target
    /// @param target The Uniswap router address
    /// @param config The swap configuration
    function setSwapConfig(address target, SwapConfig calldata config) external {
        _configs[msg.sender][target] = config;
        emit SwapConfigSet(msg.sender, target, config);
    }

    /// @notice Get swap policy configuration
    function getSwapConfig(address account, address target) external view returns (SwapConfig memory) {
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

        SwapConfig storage config = _configs[account][target];
        if (!config.active) revert PolicyNotConfigured(account, target);

        // Minimum calldata: 4 (selector) + 7*32 (7 params) = 228 bytes
        if (callData.length < 228) revert InvalidCalldata();

        // Decode exactInputSingle params from calldata
        // Skip 4 bytes selector, then read:
        //   [4:36]   = tokenIn (address, padded to 32)
        //   [36:68]  = tokenOut
        //   [68:100] = fee (uint24, padded to 32)
        //   [100:132] = recipient
        //   [132:164] = amountIn (uint256)
        address tokenIn = address(uint160(uint256(bytes32(callData[4:36]))));
        address tokenOut = address(uint160(uint256(bytes32(callData[36:68]))));
        uint24 fee = uint24(uint256(bytes32(callData[68:100])));
        address recipient = address(uint160(uint256(bytes32(callData[100:132]))));
        uint256 amountIn = uint256(bytes32(callData[132:164]));

        // Validate tokenIn
        if (config.tokenIn != address(0) && tokenIn != config.tokenIn) {
            revert InvalidTokenIn(tokenIn, config.tokenIn);
        }

        // Validate tokenOut
        if (config.tokenOut != address(0) && tokenOut != config.tokenOut) {
            revert InvalidTokenOut(tokenOut, config.tokenOut);
        }

        // Validate recipient
        if (config.recipient != address(0) && recipient != config.recipient) {
            revert InvalidRecipient(recipient, config.recipient);
        }

        // Validate fee tier
        if (config.feeTier != 0 && fee != config.feeTier) {
            revert InvalidFeeTier(fee, config.feeTier);
        }

        // Validate daily volume
        if (config.maxDailyVolume > 0) {
            DailyVolume storage vol = _dailyVolumes[account][target];
            uint256 currentDay = block.timestamp / 1 days;

            if (vol.day != currentDay) {
                vol.day = currentDay;
                vol.consumed = 0;
            }

            uint256 newConsumed = vol.consumed + amountIn;
            if (newConsumed > config.maxDailyVolume) {
                revert DailyVolumeLimitExceeded(newConsumed, config.maxDailyVolume);
            }

            vol.consumed = newConsumed;
        }

        return true;
    }
}
