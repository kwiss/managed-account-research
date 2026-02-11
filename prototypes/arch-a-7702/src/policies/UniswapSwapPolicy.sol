// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IActionPolicy} from "../interfaces/IActionPolicy.sol";

/// @title UniswapSwapPolicy
/// @notice Validates Uniswap V3 exactInputSingle swap parameters for operator session keys.
contract UniswapSwapPolicy is IActionPolicy {
    // ──────────────────── Structs ────────────────────

    struct SwapConfig {
        address[] allowedTokensIn;
        address[] allowedTokensOut;
        address requiredRecipient;
        uint24[] allowedFeeTiers;
        uint256 dailyVolumeLimit;
    }

    struct DecodedSwap {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
    }

    // ──────────────────── Errors ────────────────────

    error TokenInNotAllowed(address tokenIn);
    error TokenOutNotAllowed(address tokenOut);
    error RecipientNotAccount(address recipient, address expected);
    error FeeTierNotAllowed(uint24 fee);
    error DailyVolumeLimitExceeded(uint256 used, uint256 limit);
    error NoEthValueAllowed();
    error NotInitialized(address account);
    error InvalidCalldata();
    error OnlyAccount();
    error AlreadyInitialized(address account);

    // ──────────────────── Events ────────────────────

    event PolicyInitialized(address indexed account);

    // ──────────────────── Storage ────────────────────

    mapping(address account => SwapConfig) private _configs;
    mapping(address account => bool) private _initialized;
    mapping(address account => mapping(uint256 day => uint256 volume)) private _dailyVolume;

    // ──────────────────── Initialization ────────────────────

    /// @notice Initializes the policy for a given account.
    /// @dev Only callable by the account itself. Cannot be called if already initialized. [C-01]
    function initializePolicy(address account, SwapConfig calldata config) external {
        if (msg.sender != account) revert OnlyAccount();
        if (_initialized[account]) revert AlreadyInitialized(account);
        _configs[account] = config;
        _initialized[account] = true;
        emit PolicyInitialized(account);
    }

    // ──────────────────── IActionPolicy ────────────────────

    /// @inheritdoc IActionPolicy
    function checkAction(
        bytes32,
        address account,
        address,
        uint256 value,
        bytes calldata data
    ) external override returns (uint256) {
        if (!_initialized[account]) revert NotInitialized(account);
        if (value != 0) revert NoEthValueAllowed();
        if (data.length < 260) revert InvalidCalldata();

        DecodedSwap memory swap = _decodeSwap(data);
        _validateSwap(account, swap);

        return 0;
    }

    // ──────────────────── View Functions ────────────────────

    /// @notice Returns the daily volume used by an account today.
    function getDailyVolumeUsed(address account) external view returns (uint256) {
        uint256 today = block.timestamp / 1 days;
        return _dailyVolume[account][today];
    }

    // ──────────────────── Internal ────────────────────

    function _decodeSwap(bytes calldata data) internal pure returns (DecodedSwap memory swap) {
        // Skip 4-byte selector. Uniswap V3 ExactInputSingleParams ABI-encoded layout:
        // offset 0:  tokenIn (address, padded to 32 bytes)
        // offset 32: tokenOut
        // offset 64: fee (uint24, padded to 32 bytes)
        // offset 96: recipient
        // offset 128: deadline
        // offset 160: amountIn
        // offset 192: amountOutMin
        // offset 224: sqrtPriceLimitX96
        bytes calldata params = data[4:];
        swap.tokenIn = address(bytes20(params[12:32]));
        swap.tokenOut = address(bytes20(params[44:64]));
        swap.fee = uint24(bytes3(params[93:96]));
        swap.recipient = address(bytes20(params[108:128]));
        swap.amountIn = uint256(bytes32(params[160:192]));
    }

    function _validateSwap(address account, DecodedSwap memory swap) internal {
        SwapConfig storage config = _configs[account];

        if (!_isInArray(swap.tokenIn, config.allowedTokensIn)) {
            revert TokenInNotAllowed(swap.tokenIn);
        }
        if (!_isInArray(swap.tokenOut, config.allowedTokensOut)) {
            revert TokenOutNotAllowed(swap.tokenOut);
        }
        if (swap.recipient != config.requiredRecipient) {
            revert RecipientNotAccount(swap.recipient, config.requiredRecipient);
        }
        if (!_isInFeeTiers(swap.fee, config.allowedFeeTiers)) {
            revert FeeTierNotAllowed(swap.fee);
        }

        uint256 today = block.timestamp / 1 days;
        uint256 usedToday = _dailyVolume[account][today];
        uint256 newTotal = usedToday + swap.amountIn;
        if (newTotal > config.dailyVolumeLimit) {
            revert DailyVolumeLimitExceeded(newTotal, config.dailyVolumeLimit);
        }
        _dailyVolume[account][today] = newTotal;
    }

    function _isInArray(address value, address[] storage arr) internal view returns (bool) {
        for (uint256 i; i < arr.length; ++i) {
            if (arr[i] == value) return true;
        }
        return false;
    }

    function _isInFeeTiers(uint24 value, uint24[] storage arr) internal view returns (bool) {
        for (uint256 i; i < arr.length; ++i) {
            if (arr[i] == value) return true;
        }
        return false;
    }
}
