// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IActionPolicy} from "../interfaces/IActionPolicy.sol";

/// @title AaveSupplyPolicy
/// @notice Validates Aave V3 supply(address,uint256,address,uint16) call parameters.
contract AaveSupplyPolicy is IActionPolicy {
    // ──────────────────── Structs ────────────────────

    struct SupplyConfig {
        address[] allowedAssets;
        address requiredOnBehalfOf;
        uint256 maxSupplyPerTx;
        uint256 dailySupplyLimit;
    }

    // ──────────────────── Errors ────────────────────

    error AssetNotAllowed(address asset);
    error InvalidOnBehalfOf(address onBehalfOf, address expected);
    error ExceedsMaxSupplyPerTx(uint256 amount, uint256 max);
    error DailySupplyLimitExceeded(uint256 used, uint256 limit);
    error NoEthValueAllowed();
    error NotInitialized(address account);
    error InvalidCalldata();
    error OnlyAccount();
    error AlreadyInitialized(address account);

    // ──────────────────── Events ────────────────────

    event PolicyInitialized(address indexed account);

    // ──────────────────── Storage ────────────────────

    mapping(address account => SupplyConfig) private _configs;
    mapping(address account => bool) private _initialized;
    mapping(address account => mapping(uint256 day => uint256 supplied)) private _dailySupplied;

    // ──────────────────── Aave V3 supply layout ────────────────────
    // supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode)
    // selector + 4 × 32-byte params = 4 + 128 = 132 bytes minimum

    // ──────────────────── Initialization ────────────────────

    /// @notice Initializes the policy for a given account.
    /// @dev Only callable by the account itself. Cannot be called if already initialized. [C-01]
    function initializePolicy(address account, SupplyConfig calldata config) external {
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
        if (data.length < 132) revert InvalidCalldata();

        // Decode: skip 4-byte selector
        // asset at offset 0 (32 bytes), amount at offset 32, onBehalfOf at offset 64
        bytes calldata params = data[4:];
        address asset = address(bytes20(params[12:32]));
        uint256 amount = uint256(bytes32(params[32:64]));
        address onBehalfOf = address(bytes20(params[76:96]));

        _validateSupply(account, asset, amount, onBehalfOf);

        return 0;
    }

    // ──────────────────── View Functions ────────────────────

    /// @notice Returns the daily supply used by an account today.
    function getDailySupplyUsed(address account) external view returns (uint256) {
        uint256 today = block.timestamp / 1 days;
        return _dailySupplied[account][today];
    }

    // ──────────────────── Internal ────────────────────

    function _validateSupply(address account, address asset, uint256 amount, address onBehalfOf) internal {
        SupplyConfig storage config = _configs[account];

        if (!_isInArray(asset, config.allowedAssets)) {
            revert AssetNotAllowed(asset);
        }
        if (onBehalfOf != config.requiredOnBehalfOf) {
            revert InvalidOnBehalfOf(onBehalfOf, config.requiredOnBehalfOf);
        }
        if (amount > config.maxSupplyPerTx) {
            revert ExceedsMaxSupplyPerTx(amount, config.maxSupplyPerTx);
        }

        uint256 today = block.timestamp / 1 days;
        uint256 usedToday = _dailySupplied[account][today];
        uint256 newTotal = usedToday + amount;
        if (newTotal > config.dailySupplyLimit) {
            revert DailySupplyLimitExceeded(newTotal, config.dailySupplyLimit);
        }
        _dailySupplied[account][today] = newTotal;
    }

    function _isInArray(address value, address[] storage arr) internal view returns (bool) {
        for (uint256 i; i < arr.length; ++i) {
            if (arr[i] == value) return true;
        }
        return false;
    }
}
