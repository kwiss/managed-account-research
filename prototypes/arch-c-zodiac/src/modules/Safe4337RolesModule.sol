// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PackedUserOperation} from "../types/PackedUserOperation.sol";
import {ISafe4337RolesModule} from "../interfaces/ISafe4337RolesModule.sol";
import {IRoles} from "../interfaces/IRoles.sol";

/// @title Safe4337RolesModule
/// @notice Bridges ERC-4337 UserOps to the Zodiac Roles v2 -> Delay -> Safe pipeline
/// @dev The ONLY custom contract needed for Architecture C.
/// Flow: EntryPoint -> validateUserOp (ECDSA verify) -> executeUserOp -> Roles -> Delay -> Safe
contract Safe4337RolesModule is ISafe4337RolesModule {
    // ─── Constants ───────────────────────────────────────────────────

    /// @dev ERC-4337 validation success return value
    uint256 internal constant SIG_VALIDATION_SUCCESS = 0;

    /// @dev ERC-4337 validation failure return value
    uint256 internal constant SIG_VALIDATION_FAILED = 1;

    /// @dev Transient storage slot for operator address (keccak256("Safe4337RolesModule.operator"))
    bytes32 internal constant OPERATOR_SLOT = 0x8153528768dc386b50ec1beb14f35041baa5d27fff01c11f774b9730b419377d;

    /// @dev Transient storage slot for userOpHash (keccak256("Safe4337RolesModule.userOpHash"))
    bytes32 internal constant USEROP_HASH_SLOT = 0x6c2846f0e560ceb6ed5789e15a6d13c33b809f74c21350423feb3aa416cf43fb;

    // ─── Immutables ─────────────────────────────────────────────────

    /// @notice The chain ID at deployment time, used for cross-chain replay protection (H-02)
    uint256 public immutable DEPLOYMENT_CHAIN_ID;

    // ─── Storage ─────────────────────────────────────────────────────

    /// @notice The Safe this module is attached to
    address public safe;

    /// @notice The Zodiac Roles v2 module address
    address public rolesModule;

    /// @notice The ERC-4337 EntryPoint address
    address public entryPoint;

    /// @notice Operator configurations indexed by operator address
    mapping(address => OperatorConfig) public operators;

    // ─── Errors ──────────────────────────────────────────────────────

    /// @notice Thrown when caller is not the Safe
    error OnlySafe();

    /// @notice Thrown when caller is not the EntryPoint
    error OnlyEntryPoint();

    /// @notice Thrown when operator address is zero
    error ZeroAddress();

    /// @notice Thrown when operator is already registered
    error OperatorAlreadyExists(address operator);

    // ─── Modifiers ───────────────────────────────────────────────────

    modifier onlySafe() {
        if (msg.sender != safe) revert OnlySafe();
        _;
    }

    modifier onlyEntryPoint() {
        if (msg.sender != entryPoint) revert OnlyEntryPoint();
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────────

    /// @notice Initialize the module
    /// @param _safe The Safe address this module serves
    /// @param _entryPoint The ERC-4337 EntryPoint address
    /// @param _rolesModule The Zodiac Roles v2 module address
    constructor(address _safe, address _entryPoint, address _rolesModule) {
        // M-01: Validate all addresses including rolesModule
        if (_safe == address(0) || _entryPoint == address(0) || _rolesModule == address(0)) {
            revert ZeroAddress();
        }
        safe = _safe;
        entryPoint = _entryPoint;
        rolesModule = _rolesModule;
        // H-02: Store chain ID at deployment for cross-chain replay protection
        DEPLOYMENT_CHAIN_ID = block.chainid;
    }

    // ─── ERC-4337 Validation ─────────────────────────────────────────

    /// @inheritdoc ISafe4337RolesModule
    function validateUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 missingAccountFunds
    ) external onlyEntryPoint returns (uint256 validationData) {
        // H-02: Cross-chain replay protection
        if (block.chainid != DEPLOYMENT_CHAIN_ID) revert ChainIdMismatch();

        // H-01: Recover operator from raw userOpHash (no eth_sign prefix)
        address operator = _recoverSigner(userOpHash, userOp.signature);

        // Check operator is registered and active
        OperatorConfig storage config = operators[operator];
        if (!config.active) {
            return SIG_VALIDATION_FAILED;
        }

        // C-01: Store BOTH operator AND userOpHash in transient storage
        _setTransientOperator(operator);
        _setTransientUserOpHash(userOpHash);

        // Prefund EntryPoint if needed
        if (missingAccountFunds > 0) {
            (bool success,) = payable(entryPoint).call{value: missingAccountFunds}("");
            (success); // ignore return value — EntryPoint validates the deposit
        }

        emit UserOpValidated(operator, userOpHash);

        // H-03: Pack validUntil into the return value per ERC-4337 spec
        // validationData = authorizer (20 bytes) | validUntil (6 bytes) | validAfter (6 bytes)
        uint48 until = config.validUntil;
        if (until == 0) until = type(uint48).max; // no bound if not set
        // authorizer = 0 (success), validAfter = 0 (valid immediately)
        return uint256(uint160(0)) | (uint256(until) << 160);
    }

    // ─── ERC-4337 Execution ───────────────────────────────────────────

    /// @inheritdoc ISafe4337RolesModule
    function executeUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash
    ) external onlyEntryPoint {
        // C-01: Read operator AND hash from transient storage, then clear immediately
        address operator = _getTransientOperator();
        bytes32 storedHash = _getTransientUserOpHash();
        _clearTransientOperator();
        _clearTransientUserOpHash();

        // C-01: Verify stored hash matches current userOpHash (prevents cross-UserOp leakage)
        // C-02: This also binds the validated calldata to execution since userOpHash covers callData
        if (storedHash != userOpHash) revert UserOpHashMismatch();
        if (operator == address(0)) revert UnauthorizedOperator(address(0));

        // Decode the execution parameters from userOp.callData
        // Expected encoding: abi.encode(address target, uint256 value, bytes data)
        // The first 4 bytes of callData are the function selector for executeUserOp itself,
        // but the EntryPoint calls us directly, so we decode the inner payload
        (address target, uint256 value, bytes memory data) = _decodeExecutionCalldata(userOp.callData);

        // Get operator's role key
        uint16 roleKey = operators[operator].roleKey;

        // Route through Zodiac Roles v2 (which checks permissions and routes through Delay -> Safe)
        // operation = 0 (Call)
        bool success = IRoles(rolesModule).execTransactionWithRole(
            target,
            value,
            data,
            0, // Enum.Operation.Call
            roleKey,
            true // shouldRevert — let Roles revert with descriptive error
        );

        if (!success) revert ExecutionFailed();

        emit UserOpExecuted(operator, userOpHash);
    }

    // ─── Operator Management ─────────────────────────────────────────

    /// @inheritdoc ISafe4337RolesModule
    function addOperator(address operator, uint16 roleKey, uint48 validUntil) external onlySafe {
        if (operator == address(0)) revert ZeroAddress();
        if (operators[operator].active) revert OperatorAlreadyExists(operator);

        operators[operator] = OperatorConfig({
            operator: operator,
            roleKey: roleKey,
            active: true,
            validUntil: validUntil
        });

        emit OperatorAdded(operator, roleKey, validUntil);
    }

    /// @inheritdoc ISafe4337RolesModule
    function removeOperator(address operator) external onlySafe {
        if (!operators[operator].active) revert UnauthorizedOperator(operator);

        operators[operator].active = false;

        emit OperatorRemoved(operator);
    }

    // ─── Configuration ───────────────────────────────────────────────

    /// @inheritdoc ISafe4337RolesModule
    function setRolesModule(address _rolesModule) external onlySafe {
        if (_rolesModule == address(0)) revert ZeroAddress();
        rolesModule = _rolesModule;
    }

    // ─── Internal Helpers ────────────────────────────────────────────

    /// @dev Recover signer address from ECDSA signature using ecrecover
    /// @param hash The raw userOpHash to recover against (H-01: no eth_sign prefix)
    /// @param signature The ECDSA signature (65 bytes: r, s, v)
    /// @return signer The recovered signer address
    function _recoverSigner(bytes32 hash, bytes calldata signature) internal pure returns (address signer) {
        if (signature.length != 65) return address(0);

        bytes32 r;
        bytes32 s;
        uint8 v;

        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 0x20))
            v := byte(0, calldataload(add(signature.offset, 0x40)))
        }

        // EIP-2: restrict s to lower half order
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
            return address(0);
        }

        if (v != 27 && v != 28) return address(0);

        // H-01: Sign and recover from the raw userOpHash (no eth_sign prefix)
        signer = ecrecover(hash, v, r, s);
    }

    /// @dev Decode execution parameters from UserOp callData
    /// @notice The callData is expected to be: selector (4 bytes) + abi.encode(target, value, data)
    /// where the selector is for executeUserOp. The inner payload after the UserOp struct
    /// contains the actual execution target, value, and calldata.
    /// For simplicity, we expect the callData field of the UserOp to encode:
    /// abi.encodeWithSelector(this.executeUserOp.selector, userOp, userOpHash)
    /// but the actual target/value/data is packed in the first 4+N bytes:
    /// executeUserOp selector + PackedUserOperation + hash
    /// We use a simpler approach: the userOp.callData encodes
    /// abi.encodeWithSelector(EXECUTE_SELECTOR, target, value, data)
    function _decodeExecutionCalldata(bytes calldata callData)
        internal
        pure
        returns (address target, uint256 value, bytes memory data)
    {
        // Skip the first 4 bytes (function selector)
        // The remaining bytes are abi.encode(address, uint256, bytes)
        if (callData.length < 4) revert ExecutionFailed();
        (target, value, data) = abi.decode(callData[4:], (address, uint256, bytes));
    }

    // ─── Transient Storage Helpers ──────────────────────────────────

    /// @dev Store operator address in transient storage
    function _setTransientOperator(address operator) internal {
        assembly {
            tstore(OPERATOR_SLOT, operator)
        }
    }

    /// @dev Read operator address from transient storage
    function _getTransientOperator() internal view returns (address operator) {
        assembly {
            operator := tload(OPERATOR_SLOT)
        }
    }

    /// @dev Clear operator from transient storage (C-01)
    function _clearTransientOperator() internal {
        assembly {
            tstore(OPERATOR_SLOT, 0)
        }
    }

    /// @dev Store userOpHash in transient storage (C-01)
    function _setTransientUserOpHash(bytes32 hash) internal {
        assembly {
            tstore(USEROP_HASH_SLOT, hash)
        }
    }

    /// @dev Read userOpHash from transient storage (C-01)
    function _getTransientUserOpHash() internal view returns (bytes32 hash) {
        assembly {
            hash := tload(USEROP_HASH_SLOT)
        }
    }

    /// @dev Clear userOpHash from transient storage (C-01)
    function _clearTransientUserOpHash() internal {
        assembly {
            tstore(USEROP_HASH_SLOT, 0)
        }
    }

    /// @dev Allow the contract to receive ETH (for EntryPoint prefunding)
    receive() external payable {}
}
