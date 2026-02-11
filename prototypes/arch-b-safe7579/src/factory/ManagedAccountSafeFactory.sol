// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;



/// @title ISafeProxyFactory
/// @notice Minimal interface for Safe proxy factory
interface ISafeProxyFactory {
    function createProxyWithNonce(address singleton, bytes memory initializer, uint256 saltNonce)
        external
        returns (address proxy);

    function proxyCreationCode() external pure returns (bytes memory);
}

/// @title ISafe7579Launchpad
/// @notice Minimal interface for Safe7579 Launchpad (bootstraps Safe + 7579 in a single UserOp)
interface ISafe7579Launchpad {
    struct ModuleInit {
        address module;
        bytes initData;
    }

    /// @notice Encodes the setup call for Safe7579 initialization
    function getInitCode(
        address safe7579,
        address ownableValidator,
        bytes memory ownableValidatorInitData,
        ModuleInit[] memory executors,
        ModuleInit[] memory fallbacks,
        ModuleInit[] memory hooks,
        address[] memory attesters,
        uint8 attesterThreshold
    ) external view returns (bytes memory);

    /// @notice Hashes the initialization data for CREATE2 prediction
    function hash(
        address safe7579,
        address ownableValidator,
        bytes memory ownableValidatorInitData,
        ModuleInit[] memory executors,
        ModuleInit[] memory fallbacks,
        ModuleInit[] memory hooks,
        address[] memory attesters,
        uint8 attesterThreshold
    ) external view returns (bytes32);
}

/// @title ManagedAccountSafeFactory
/// @notice Factory for deploying Safe + Safe7579 + all ManagedAccount modules
/// @dev Generates initCode and setup calldata for ERC-4337 account deployment
///
/// Architecture:
///   Safe (account) ─── Safe7579 Adapter ─── ERC-7579 Modules
///                                            ├── OwnableValidator (signers)
///                                            ├── SmartSession (session keys)
///                                            ├── HookMultiPlexer ─── TimelockHook
///                                            └── (Policies configured via SmartSession)
contract ManagedAccountSafeFactory {
    // ─── Immutable References ────────────────────────────────────────────────

    /// @notice Safe singleton (implementation) address
    address public immutable safeSingleton;

    /// @notice Safe7579 adapter address
    address public immutable safe7579;

    /// @notice Safe7579 Launchpad address (bootstraps Safe + 7579 in one tx)
    address public immutable safe7579Launchpad;

    /// @notice Safe proxy factory address
    address public immutable safeProxyFactory;

    /// @notice SmartSession module address
    address public immutable smartSession;

    /// @notice HookMultiPlexer address
    address public immutable hookMultiplexer;

    /// @notice ManagedAccountTimelockHook address
    address public immutable timelockHook;

    /// @notice OwnableValidator module address
    address public immutable ownableValidator;

    // ─── Structs ─────────────────────────────────────────────────────────────

    /// @notice Parameters for deploying a new ManagedAccount
    struct DeploymentParams {
        /// @dev Safe owner addresses
        address[] owners;
        /// @dev Safe threshold for multi-sig
        uint256 threshold;
        /// @dev Timelock cooldown period in seconds
        uint256 timelockCooldown;
        /// @dev Timelock expiration window in seconds
        uint256 timelockExpiration;
        /// @dev Array of target+selector pairs that bypass the timelock
        ImmediateSelector[] immediateSelectors;
        /// @dev Salt for CREATE2 deterministic deployment
        bytes32 salt;
    }

    /// @notice A target+selector pair for immediate execution
    struct ImmediateSelector {
        address target;
        bytes4 selector;
    }

    // ─── Events ──────────────────────────────────────────────────────────────

    event ManagedAccountDeployed(address indexed account, address[] owners, uint256 threshold);

    // ─── Errors ──────────────────────────────────────────────────────────────

    error InvalidParams();

    // ─── Constructor ─────────────────────────────────────────────────────────

    constructor(
        address _safeSingleton,
        address _safe7579,
        address _safe7579Launchpad,
        address _safeProxyFactory,
        address _smartSession,
        address _hookMultiplexer,
        address _timelockHook,
        address _ownableValidator
    ) {
        safeSingleton = _safeSingleton;
        safe7579 = _safe7579;
        safe7579Launchpad = _safe7579Launchpad;
        safeProxyFactory = _safeProxyFactory;
        smartSession = _smartSession;
        hookMultiplexer = _hookMultiplexer;
        timelockHook = _timelockHook;
        ownableValidator = _ownableValidator;
    }

    // ─── External Functions ──────────────────────────────────────────────────

    /// @notice Computes the Safe7579 Launchpad initCode for EntryPoint deployment
    /// @param params Deployment parameters
    /// @return initCode The initCode bytes for the ERC-4337 UserOperation
    function getInitCode(DeploymentParams calldata params) external view returns (bytes memory initCode) {
        if (params.owners.length == 0 || params.threshold == 0 || params.threshold > params.owners.length) {
            revert InvalidParams();
        }

        bytes memory setupCalldata = _buildSetupCalldata(params);

        // initCode = safeProxyFactory address + createProxyWithNonce calldata
        // The proxy factory will deploy a new Safe proxy pointing to the singleton
        // and call the setup function (which bootstraps Safe7579)
        initCode = abi.encodePacked(
            safeProxyFactory,
            abi.encodeCall(
                ISafeProxyFactory.createProxyWithNonce, (safe7579Launchpad, setupCalldata, uint256(params.salt))
            )
        );
    }

    /// @notice Encodes the setup calldata for Safe7579 initialization
    /// @param params Deployment parameters
    /// @return calldata_ The encoded setupSafe call with all module installations
    function getSetupCalldata(DeploymentParams calldata params) external view returns (bytes memory calldata_) {
        return _buildSetupCalldata(params);
    }

    /// @notice Predicts the CREATE2 address of a Safe deployment
    /// @param params Deployment parameters
    /// @return predicted The predicted address
    function predictAddress(DeploymentParams calldata params) external view returns (address predicted) {
        bytes memory setupCalldata = _buildSetupCalldata(params);

        // Safe proxy creation code + constructor args (singleton address)
        bytes memory proxyCreationCode = ISafeProxyFactory(safeProxyFactory).proxyCreationCode();
        bytes memory deploymentData = abi.encodePacked(proxyCreationCode, uint256(uint160(safe7579Launchpad)));

        // Salt = keccak256(keccak256(setupCalldata) + saltNonce)
        bytes32 salt = keccak256(abi.encodePacked(keccak256(setupCalldata), uint256(params.salt)));

        // CREATE2: keccak256(0xff ++ factory ++ salt ++ keccak256(bytecode))
        predicted = address(
            uint160(
                uint256(keccak256(abi.encodePacked(bytes1(0xff), safeProxyFactory, salt, keccak256(deploymentData))))
            )
        );
    }

    // ─── Internal Functions ──────────────────────────────────────────────────

    /// @dev Builds the setup calldata that initializes Safe7579 with all modules
    function _buildSetupCalldata(DeploymentParams calldata params) internal view returns (bytes memory) {
        // Encode OwnableValidator init data (owners + threshold)
        bytes memory validatorInitData = abi.encode(params.owners, params.threshold);

        // Build executor module inits (SmartSession as executor)
        ISafe7579Launchpad.ModuleInit[] memory executors = new ISafe7579Launchpad.ModuleInit[](1);
        executors[0] = ISafe7579Launchpad.ModuleInit({module: smartSession, initData: ""});

        // No fallback modules needed
        ISafe7579Launchpad.ModuleInit[] memory fallbacks = new ISafe7579Launchpad.ModuleInit[](0);

        // Build hook init data — HookMultiPlexer with TimelockHook
        // H-02: TimelockHook.onInstall now uses msg.sender as safeAccount, so only pass cooldown + expiration
        // H-05: HookMultiPlexer.onInstall expects abi.encode(address[]), not abi.encode(address, bytes)
        address[] memory hookAddresses = new address[](1);
        hookAddresses[0] = timelockHook;
        bytes memory hookInitData = abi.encode(hookAddresses);

        ISafe7579Launchpad.ModuleInit[] memory hooks = new ISafe7579Launchpad.ModuleInit[](1);
        hooks[0] = ISafe7579Launchpad.ModuleInit({module: hookMultiplexer, initData: hookInitData});

        // No attesters for prototype
        address[] memory attesters = new address[](0);
        uint8 attesterThreshold = 0;

        // Encode the launchpad getInitCode call
        return ISafe7579Launchpad(safe7579Launchpad).getInitCode(
            safe7579, ownableValidator, validatorInitData, executors, fallbacks, hooks, attesters, attesterThreshold
        );
    }
}
