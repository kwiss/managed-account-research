# Security Review: Arch C (Safe + Zodiac)

**Auditor**: Internal Security Review
**Date**: 2026-02-11
**Revision**: 2 (comprehensive re-audit)
**Scope**: All Solidity source files in `prototypes/arch-c-zodiac/src/` and `prototypes/arch-c-zodiac/test/`
**Focus**: Safe4337RolesModule -- the only custom contract bridging ERC-4337 and the Zodiac pipeline

---

## Executive Summary

Architecture C employs a minimalist design: a single custom contract (`Safe4337RolesModule`, ~257 LOC) bridges ERC-4337 UserOperations into the battle-tested Zodiac Roles v2 and Delay module chain. The attack surface is substantially smaller than Architectures A and B because both the permission engine (Zodiac Roles v2) and the timelock (Zodiac Delay) are off-the-shelf, audited contracts.

Despite this, the bridge module introduces **critical** security concerns centered on three categories:

1. **Transient storage safety**: The mechanism for passing operator identity from `validateUserOp` to `executeUserOp` via EIP-1153 transient storage is vulnerable to cross-UserOp leakage within `handleOps` batches. Transient storage is never cleared after use, creating an operator impersonation vector.

2. **Validation/execution decoupling**: The module does not independently bind the validated calldata to the execution calldata. While the ERC-4337 EntryPoint provides this guarantee, the module itself has zero defense-in-depth.

3. **Non-standard signing scheme**: The use of `eth_sign` prefix diverges from ERC-4337 conventions, creating integration friction and potential signature incompatibility with standard Account Abstraction tooling.

Additionally, the mock contracts used in testing deviate significantly from real Zodiac module behavior, particularly in member assignment enforcement. Tests will pass with mocks but will fail with production Zodiac deployments until the Safe4337RolesModule is properly registered as a role member.

**Overall Risk Rating**: Medium-High (for the bridge module in isolation; significantly lower when the Zodiac modules function as additional defense layers)

| Severity | Count |
|----------|-------|
| Critical | 2 |
| High | 3 |
| Medium | 5 |
| Low | 6 |
| Informational | 5 |

---

## Critical Findings

### C-01: Transient Storage Never Cleared -- Cross-UserOp Operator Leakage

**Severity**: Critical
**Contract**: `Safe4337RolesModule.sol` lines 99-100, 119-121
**Status**: Confirmed

**Description**:

The module stores the validated operator address in transient storage (EIP-1153) during `validateUserOp` (line 100) and reads it during `executeUserOp` (line 120). The transient storage slot is **never cleared** after reading.

```solidity
// validateUserOp -- SETS transient storage
_setTransientOperator(operator);   // line 100

// executeUserOp -- READS but does NOT clear
address operator = _getTransientOperator();  // line 120
// No _clearTransientOperator() call anywhere
```

EIP-1153 specifies that transient storage persists for the duration of the entire transaction and follows normal revert semantics within sub-calls. In an ERC-4337 `handleOps` batch:

1. **EntryPoint processes UserOps sequentially** within a single transaction.
2. `validateUserOp` for UserOp_A sets transient operator to Alice.
3. `executeUserOp` for UserOp_A reads Alice -- correct.
4. **Alice's operator context remains in transient storage.**
5. If `validateUserOp` for UserOp_B fails (e.g., invalid signature from Bob), transient storage still holds Alice.
6. If by any codepath `executeUserOp` is invoked again with stale transient state, it would operate as Alice.

The specific attack scenario depends on EntryPoint implementation details. In the canonical v0.7 EntryPoint, validation and execution are in separate loops (all validations run first, then all executions). This means:

- Validation loop: validate(A) sets tstore=Alice, validate(B) sets tstore=Bob
- Execution loop: execute(A) reads tstore=Bob (wrong!), execute(B) reads tstore=Bob

**This is a direct operator impersonation vulnerability in batched operations.** UserOp_A, signed by Alice, would execute with Bob's roleKey and permissions if Bob's UserOp validates after Alice's.

**Impact**: Operator impersonation. UserOps in the same `handleOps` batch will use the **last validated operator's** identity for all executions, regardless of which operator actually signed each UserOp.

**Proof of Concept** (not in current tests):
```solidity
// Attacker scenario:
// 1. Alice (roleKey=1, limited permissions) signs UserOp_A
// 2. Bob (roleKey=99, broad permissions) signs UserOp_B
// 3. Bundler includes both in handleOps([UserOp_A, UserOp_B])
// 4. Validation phase: validate(A) -> tstore=Alice, validate(B) -> tstore=Bob
// 5. Execution phase: execute(A) reads tstore=Bob -- Alice's UserOp runs with Bob's permissions
```

**Recommendation**:
1. Clear transient storage immediately after reading in `executeUserOp`.
2. Store the `userOpHash` alongside the operator in transient storage to bind the validated identity to a specific UserOp.
3. Verify the hash matches in `executeUserOp`.

```solidity
// In validateUserOp:
_setTransientOperator(operator);
_setTransientUserOpHash(userOpHash);

// In executeUserOp:
address operator = _getTransientOperator();
bytes32 storedHash = _getTransientUserOpHash();
_clearTransientOperator();
_clearTransientUserOpHash();
if (storedHash != userOpHash) revert OperatorHashMismatch();
if (operator == address(0)) revert UnauthorizedOperator(address(0));
```

Even with this fix, the fundamental issue remains that a single transient slot cannot safely serve multiple UserOps in a batch. A mapping approach (keyed by `userOpHash`) is more robust but requires additional transient storage management.

---

### C-02: Validation-Execution Calldata Decoupling -- No Independent Integrity Check

**Severity**: Critical
**Contract**: `Safe4337RolesModule.sol` lines 85-146
**Status**: Confirmed

**Description**:

`validateUserOp` verifies the operator's signature over `userOpHash` and confirms the operator is active. `executeUserOp` then decodes the execution target, value, and data from `userOp.callData`. **The module does not verify any relationship between the signed hash and the calldata used for execution.**

The security model relies entirely on the EntryPoint to ensure that:
1. `userOpHash` is computed over the full `PackedUserOperation` (including `callData`)
2. The same `userOp` struct is passed to both `validateUserOp` and `executeUserOp`

While the standard ERC-4337 EntryPoint does provide these guarantees, the module has **zero defense-in-depth**:

- If the module is called outside of the ERC-4337 context (even by the real EntryPoint but through a non-standard codepath), the validation and execution are completely decoupled.
- The `onlyEntryPoint` modifier only checks `msg.sender`, not the integrity of the data flow.
- There is no on-chain verification that the calldata being executed was the calldata that was validated.

**Concrete risk scenario**: Consider a modified or wrapped EntryPoint that reuses validation results. If `validateUserOp` succeeds for a benign UserOp, and the wrapper then calls `executeUserOp` with a different (malicious) UserOp but the same operator in transient storage, the malicious calldata would execute with the operator's permissions.

Combined with C-01 (transient storage never cleared), this becomes more dangerous: any call to `executeUserOp` after any successful `validateUserOp` in the same transaction will find a valid operator in transient storage.

**Impact**: Complete bypass of operator signature verification if the EntryPoint is non-standard, wrapped, or if the module is called in an unexpected context.

**Recommendation**: Store a hash of the validated calldata in transient storage and verify it in `executeUserOp`:

```solidity
// In validateUserOp:
_setTransientCallDataHash(keccak256(userOp.callData));

// In executeUserOp:
if (keccak256(userOp.callData) != _getTransientCallDataHash()) revert CalldataMismatch();
_clearTransientCallDataHash();
```

---

## High Findings

### H-01: Non-Standard eth_sign Prefix Breaks ERC-4337 SDK Compatibility

**Severity**: High
**Contract**: `Safe4337RolesModule.sol` lines 213-216
**Status**: Confirmed

**Description**:

The `_recoverSigner` function applies the `"\x19Ethereum Signed Message:\n32"` prefix before `ecrecover`:

```solidity
bytes32 ethSignedHash = keccak256(
    abi.encodePacked("\x19Ethereum Signed Message:\n32", hash)
);
signer = ecrecover(ethSignedHash, v, r, s);
```

In the standard ERC-4337 ecosystem:
- The EntryPoint computes `userOpHash = keccak256(abi.encode(userOp.hash(), address(entryPoint), block.chainid))`
- The account (or module) is expected to recover the signer from `userOpHash` directly, or using EIP-712 typed data signing
- Standard AA SDKs (permissionless.js, Alchemy AA SDK, Biconomy SDK) sign the raw `userOpHash` without the `eth_sign` prefix

Using the `eth_sign` prefix means:

1. **SDK incompatibility**: Every AA SDK integration must be custom-modified to use `personal_sign` or manual `eth_sign` prefix. This is a significant development overhead.
2. **Wallet incompatibility**: Many wallets have deprecated or disabled `eth_sign` due to phishing concerns (EIP-191 prefix on arbitrary hashes allows attackers to trick users into signing transactions).
3. **Double-hashing risk**: The operator signs `keccak256(prefix || userOpHash)` instead of `userOpHash`. If any part of the stack expects raw `userOpHash` signatures, validation will silently fail (return `SIG_VALIDATION_FAILED = 1`), which is non-obvious to debug.

**Impact**: Integration failure with standard ERC-4337 tooling. All operator signing tooling must be custom-built. Potential for silent signature mismatches that are difficult to debug.

**Recommendation**: Remove the `eth_sign` prefix and recover from the raw `userOpHash`:

```solidity
function _recoverSigner(bytes32 hash, bytes calldata signature) internal pure returns (address signer) {
    // ... length and s-value checks ...
    signer = ecrecover(hash, v, r, s);  // sign raw userOpHash
}
```

Or adopt EIP-712 typed data signing for a structured approach.

---

### H-02: No Cross-Chain Replay Protection at Module Level

**Severity**: High
**Contract**: `Safe4337RolesModule.sol`
**Status**: Confirmed

**Description**:

The module contains no chain-specific data in its validation logic. Cross-chain replay protection is fully delegated to the EntryPoint, which includes `block.chainid` in its `userOpHash` computation.

However:
1. The module has no independent `chainId` check. If deployed to two chains with the same address (via CREATE2 with identical init parameters), and a non-standard EntryPoint is used on one chain, signatures could be replayed.
2. The `OPERATOR_SLOT` transient storage constant is the same on all chains, so there is no chain-level isolation at the transient storage layer.
3. The module does not include `address(this)` in any validation, so two instances of the module on the same chain could theoretically share operator signatures if they use the same EntryPoint.

**Specific scenario**: If the same module contract is deployed on Ethereum mainnet and a fork chain (e.g., after a hard fork) with the same EntryPoint address, all signed UserOps from before the fork are valid on both chains.

**Impact**: Cross-chain or cross-fork signature replay. Mitigated by the standard EntryPoint including `chainid` and `entrypoint address` in `userOpHash`, but violated defense-in-depth principle.

**Recommendation**: Add module-level replay protection:
```solidity
// Store at construction
uint256 public immutable CHAIN_ID = block.chainid;

// In validateUserOp:
if (block.chainid != CHAIN_ID) revert ChainIdMismatch();
```

---

### H-03: Missing validAfter/validUntil in Validation Return Value

**Severity**: High
**Contract**: `Safe4337RolesModule.sol` lines 89, 109
**Status**: Confirmed

**Description**:

The `validateUserOp` function always returns `0` (success) or `1` (failure). The ERC-4337 specification packs the return value as:

```
validationData = authorizer (20 bytes) | validUntil (6 bytes) | validAfter (6 bytes)
```

Where `authorizer = 0` means success, `authorizer = 1` means failure. The `validAfter` and `validUntil` fields define a time window during which the UserOp is valid.

By returning bare `0`, the module declares that validated UserOps have **no time bound** -- they are valid from `validAfter = 0` (genesis) to `validUntil = 0` (interpreted as infinity by the EntryPoint).

This creates a dangerous gap:
1. An operator signs a UserOp at time T.
2. The operator is compromised at time T+1. The Safe owner removes the operator.
3. If the removal and the UserOp land in the same block (with the UserOp first), the UserOp executes despite the operator being "removed."
4. Even without same-block issues, if the attacker submits the UserOp to a private mempool before the removal is mined, a cooperative bundler could include it.

Without time-bounding, there is no way for operators to set session-like expiry on their UserOps.

**Impact**: Indefinite validity of signed UserOps. Compromised operator keys remain a threat until the actual removal transaction is mined. No support for time-scoped operator sessions.

**Recommendation**: Support time-bounded validation:

```solidity
// Decode validAfter/validUntil from signature or operator config
uint48 validAfter = operators[operator].validAfter;
uint48 validUntil = operators[operator].validUntil;

// Pack the return value per ERC-4337 spec
return uint256(uint160(0)) | (uint256(validUntil) << 160) | (uint256(validAfter) << 208);
```

---

## Medium Findings

### M-01: Constructor Allows Zero Address for rolesModule and delayModule

**Severity**: Medium
**Contract**: `Safe4337RolesModule.sol` lines 74-80
**Status**: Confirmed

**Description**:

The constructor validates `_safe` and `_entryPoint` but not `_rolesModule` and `_delayModule`:

```solidity
constructor(address _safe, address _entryPoint, address _rolesModule, address _delayModule) {
    if (_safe == address(0) || _entryPoint == address(0)) revert ZeroAddress();
    safe = _safe;
    entryPoint = _entryPoint;
    rolesModule = _rolesModule;   // No zero check
    delayModule = _delayModule;   // No zero check
}
```

If `rolesModule` is `address(0)`, `executeUserOp` will call `IRoles(address(0)).execTransactionWithRole(...)`, which will call the zero address. On EVM, calling the zero address with no code succeeds and returns empty data, which `abi.decode` would fail on, causing a revert. However, the behavior is non-obvious and the error message would be opaque.

**Impact**: Deployment with zero `rolesModule` renders all operator executions non-functional with obscure errors. Deployment with zero `delayModule` has no immediate effect (since `delayModule` is never used in execution), but creates misleading state.

**Recommendation**: Validate all addresses in the constructor:
```solidity
if (_safe == address(0) || _entryPoint == address(0)
    || _rolesModule == address(0) || _delayModule == address(0)) revert ZeroAddress();
```

---

### M-02: ZodiacSetupHelper Access Control Model Is Ambiguous and Fragile

**Severity**: Medium
**Contract**: `ZodiacSetupHelper.sol` lines 38-62
**Status**: Confirmed

**Description**:

The `setup()` function has no explicit access control. It makes external calls to:
1. `safe.enableModule(...)` -- requires `msg.sender` to be the Safe itself (self-call via delegatecall or authorized caller)
2. `delay.setTxCooldown(...)` -- requires owner in real Delay module
3. `bridgeModule.addOperator(...)` -- requires `msg.sender == safe` per `onlySafe` modifier

For this function to work:
- It must be called via `delegatecall` from the Safe (so `msg.sender` in sub-calls is the Safe's address)
- OR the Safe must call this function, which then calls back -- but `msg.sender` in the sub-calls would be the helper address, not the Safe

If called via `delegatecall` from the Safe, there is a critical subtlety: the code executes in the Safe's storage context. The `ISafe(params.safe)` call becomes a self-call from the Safe, which works. But `enableModule` modifies storage, and since this is a delegatecall, the storage being modified is the Safe's storage -- which is the desired behavior.

**However**, if called as a regular `call` (not delegatecall), every sub-call that requires Safe authorization will fail. The comment says "Must be called by the Safe (via execTransaction)" but does not specify `operation = DelegateCall`.

**Impact**: Misconfigured deployment if called as a regular call instead of delegatecall. All sub-calls would revert, but the failure mode is non-obvious.

**Recommendation**:
1. Add an explicit check: `require(address(this) == params.safe, "must be called via delegatecall from Safe")`
2. Or restructure to use `safe.execTransaction()` calls instead of direct calls, so it works from any caller.

---

### M-03: Operator Removal Race Condition with Pending UserOps

**Severity**: Medium
**Contract**: `Safe4337RolesModule.sol` lines 164-171
**Status**: Confirmed

**Description**:

When an operator is removed, `removeOperator` sets `active = false`. A UserOp already in a bundler's mempool or about to be submitted can still execute if it lands in a block before the removal transaction:

```
Timeline:
T0: Operator Alice signs UserOp_X
T1: Safe owner submits removeOperator(Alice) -- pending in mempool
T2: Bundler includes UserOp_X in block N (validates successfully, Alice still active)
T3: removeOperator(Alice) included in block N+1
```

Worse, if both transactions target the same block, execution order depends on gas price / MEV. An operator being removed can front-run the removal with a higher-gas-price UserOp.

The Roles module provides defense-in-depth: even if the UserOp validates, the operator can only execute actions permitted by their roleKey. But the race window exists.

**Impact**: A removed operator can execute one final UserOp if they front-run the removal transaction. Constrained by Roles permissions.

**Recommendation**: Consider a two-phase removal (pending -> inactive) with a mandatory delay, or accept this risk given the Roles module backstop.

---

### M-04: delayModule Storage Variable Is Never Used in Execution Path

**Severity**: Medium
**Contract**: `Safe4337RolesModule.sol` lines 33, 79, 182-185
**Status**: Confirmed

**Description**:

The `delayModule` state variable is set in the constructor and has a setter (`setDelayModule`), but is never referenced in any execution path. The module calls `IRoles.execTransactionWithRole()` and relies on the Roles module to internally route through the Delay module.

This creates a dangerous false sense of security:
1. A developer may believe that changing `delayModule` via `setDelayModule()` affects the execution chain. It does not.
2. The actual Delay module in the chain is determined by the Roles module's avatar/target configuration, not by this variable.
3. If the Roles module is reconfigured to bypass the Delay module, the `delayModule` variable in this contract would not reflect that change.

**Impact**: Misleading state variable. Potential misconfiguration if operators rely on this variable for off-chain monitoring of the Delay module address.

**Recommendation**: Either remove `delayModule` entirely (and `setDelayModule`), or use it in the execution path to explicitly verify the chain includes the expected Delay module.

---

### M-05: MockRoles Does Not Enforce Member Assignment -- Tests Are Unreliable

**Severity**: Medium
**Contract**: `MockRoles.sol`
**Status**: Confirmed

**Description**:

The real Zodiac Roles v2 module requires that the caller (`msg.sender`) be assigned as a **member** of the specified role before `execTransactionWithRole` succeeds. The MockRoles skips this check entirely:

```solidity
function execTransactionWithRole(
    address to, uint256 value, bytes calldata data,
    uint8 operation, uint16 roleKey, bool shouldRevert
) external override returns (bool) {
    // MISSING: Check that msg.sender is a member of roleKey
    // Real Roles v2: require(members[roleKey][msg.sender], "not a member")

    bytes4 selector = bytes4(data[:4]);
    bool allowed = allowedFunctions[roleKey][to][selector] || scopedTargets[roleKey][to];
    // ...
}
```

In the real deployment:
1. The `Safe4337RolesModule` calls `IRoles(rolesModule).execTransactionWithRole(..., roleKey, ...)`
2. The Roles module checks that `msg.sender` (the Safe4337RolesModule address) is a member of `roleKey`
3. If not a member, the call reverts

**The ZodiacSetupHelper does not configure member assignment.** There is no call to `roles.assignRoles(safe4337RolesModule, [roleKey], [true])` in any setup code. This means:
- All integration tests pass with the mock
- The same code deployed with real Zodiac Roles v2 would fail on every `executeUserOp` call

**Impact**: False confidence in test results. Production deployment will fail unless member assignment is separately configured.

**Recommendation**:
1. Add member assignment to the `ZodiacSetupHelper.setup()` function
2. Add member assignment checks to `MockRoles`
3. Or at minimum, add a comment in the integration tests documenting this gap

---

## Low Findings

### L-01: OPERATOR_SLOT Value Does Not Match Claimed keccak256 Derivation

**Severity**: Low
**Contract**: `Safe4337RolesModule.sol` line 22
**Status**: Confirmed

**Description**:

```solidity
/// @dev Transient storage slot for operator address (keccak256("Safe4337RolesModule.operator"))
bytes32 internal constant OPERATOR_SLOT = 0x5e6f7e8d9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d;
```

The comment claims the slot is derived from `keccak256("Safe4337RolesModule.operator")`. The actual keccak256 of that string is `0x8aab...` (different). The hardcoded value `0x5e6f7e8d...` appears to be an arbitrary hex string that resembles a sequential pattern rather than a hash output.

While transient storage slot collisions are extremely unlikely with any 32-byte value, the misleading documentation could cause confusion during code review or if the pattern is replicated for additional transient storage slots.

**Impact**: Misleading documentation. No functional impact.

**Recommendation**: Compute the actual keccak256 hash and use it, or remove the misleading comment.

---

### L-02: No Event Emissions for setRolesModule and setDelayModule

**Severity**: Low
**Contract**: `Safe4337RolesModule.sol` lines 176-185
**Status**: Confirmed

**Description**:

Configuration changes to `rolesModule` and `delayModule` emit no events:

```solidity
function setRolesModule(address _rolesModule) external onlySafe {
    if (_rolesModule == address(0)) revert ZeroAddress();
    rolesModule = _rolesModule;
    // No event
}
```

Off-chain monitoring systems cannot detect when these critical configuration parameters change. A compromised Safe owner could silently swap the Roles module to a permissive one.

**Impact**: Reduced observability. Harder to detect malicious reconfiguration.

**Recommendation**: Emit events:
```solidity
event RolesModuleUpdated(address indexed oldModule, address indexed newModule);
event DelayModuleUpdated(address indexed oldModule, address indexed newModule);
```

---

### L-03: removeOperator Leaves Stale Data in Storage (No Gas Refund)

**Severity**: Low
**Contract**: `Safe4337RolesModule.sol` lines 164-171
**Status**: Confirmed

**Description**:

When an operator is removed, only `active` is set to `false`. The `operator` address and `roleKey` remain in storage:

```solidity
function removeOperator(address operator) external onlySafe {
    if (!operators[operator].active) revert UnauthorizedOperator(operator);
    operators[operator].active = false;
    // operator and roleKey remain in storage
}
```

Setting the full struct to zero would:
1. Provide an EVM gas refund (SSTORE to zero refunds gas)
2. Remove stale data that could be confusing in off-chain queries
3. Require modifying the re-addition check (currently `addOperator` checks `active` flag, which works because removed operators have `active = false`)

**Impact**: Minor gas waste. Stale storage data. No functional issue since `addOperator` correctly handles re-addition of removed operators.

**Recommendation**: Consider `delete operators[operator]` for gas refund and cleaner state.

---

### L-04: Hardcoded Operation Type Prevents DelegateCall

**Severity**: Low
**Contract**: `Safe4337RolesModule.sol` line 138
**Status**: Design Choice

**Description**:

The `executeUserOp` function hardcodes `operation = 0` (Call) when forwarding to Roles:

```solidity
bool success = IRoles(rolesModule).execTransactionWithRole(
    target, value, data,
    0, // Enum.Operation.Call -- hardcoded
    roleKey,
    true
);
```

This prevents operators from executing DelegateCall operations through the module. While this is likely an intentional security decision (preventing operators from executing arbitrary code in the Safe's context), it limits functionality:

1. MultiSend via DelegateCall is not possible (common pattern for batch operations)
2. Any protocol requiring DelegateCall interaction is inaccessible through this module

**Impact**: Reduced functionality. Operators cannot use MultiSend for batch operations or interact with protocols requiring DelegateCall.

**Recommendation**: If DelegateCall is intentionally disabled, document this explicitly. If it should be supported, decode the operation type from the calldata alongside target, value, and data, but add additional safeguards (e.g., only allow DelegateCall to whitelisted targets like MultiSend).

---

### L-05: Prefund ETH Transfer Ignores Return Value

**Severity**: Low
**Contract**: `Safe4337RolesModule.sol` lines 103-106
**Status**: Confirmed

**Description**:

```solidity
if (missingAccountFunds > 0) {
    (bool success,) = payable(entryPoint).call{value: missingAccountFunds}("");
    (success); // ignore return value
}
```

If the module has insufficient ETH balance, the `call` will fail, `success` will be `false`, and execution continues. The EntryPoint will then reject the UserOp due to insufficient deposit. While the end result is correct (UserOp fails), the error message from the EntryPoint will be opaque compared to a module-level revert.

Additionally, the pattern `(success);` is a compiler warning suppression that may confuse readers into thinking the return value is being used.

**Impact**: Obscure error messages on prefund failure. Potentially confusing code pattern.

**Recommendation**: Revert on failure:
```solidity
if (!success) revert PrefundFailed();
```

---

### L-06: No Reentrancy Guard on External Calls

**Severity**: Low
**Contract**: `Safe4337RolesModule.sol` lines 134-141
**Status**: Confirmed

**Description**:

`executeUserOp` makes an external call to `IRoles.execTransactionWithRole()`, which may call Delay, which calls Safe, which executes the actual target. This call chain involves multiple external calls with no reentrancy protection on the module.

The `onlyEntryPoint` modifier limits entry to the EntryPoint, and the Zodiac chain does not include a path back to the module. However, if the execution target (the DeFi protocol being called) has a callback mechanism (e.g., ERC-777 token hooks, flash loan callbacks), and if the callback somehow reaches the EntryPoint and triggers another `executeUserOp` call, reentrancy could occur.

In practice, the EntryPoint is not reentrant per the ERC-4337 specification. The risk is theoretical.

**Impact**: Extremely low. No known attack path. Noted for defense-in-depth.

**Recommendation**: Consider adding OpenZeppelin's `ReentrancyGuard` or a simple `bool locked` check, especially if the contract evolves.

---

## Informational

### I-01: delayModule Variable Creates Architectural Confusion

**Severity**: Informational
**Contract**: `Safe4337RolesModule.sol` line 33

**Description**: As detailed in M-04, the `delayModule` state variable is never used in execution. Its presence in the contract, along with a setter function, implies it is part of the execution logic when it is not. This creates confusion about the module's architecture.

The actual execution chain is: Module -> Roles -> (Roles internally routes to Delay) -> (Delay routes to Safe). The module has no direct interaction with the Delay module.

**Recommendation**: Remove `delayModule` and `setDelayModule()`, or clearly document that it is a reference-only field for off-chain consumption.

---

### I-02: Unreachable Code in executeUserOp

**Severity**: Informational
**Contract**: `Safe4337RolesModule.sol` lines 143-144

**Description**:

```solidity
bool success = IRoles(rolesModule).execTransactionWithRole(
    target, value, data, 0, roleKey,
    true // shouldRevert
);
if (!success) revert ExecutionFailed();  // UNREACHABLE
```

The `shouldRevert = true` parameter instructs the Roles module to revert with a descriptive error on permission failure. If Roles reverts, execution never reaches line 143. If Roles does not revert, `success` must be `true`. Therefore, the `if (!success)` check is dead code.

**Recommendation**: Remove the dead code or change `shouldRevert` to `false` and rely on the module's own `ExecutionFailed` error (less descriptive but gives the module control over error handling).

---

### I-03: MockSafe.enableModule Has No Duplicate Check

**Severity**: Informational
**Contract**: `MockSafe.sol` line 73

**Description**: The MockSafe's `enableModule` silently succeeds if a module is already enabled. The real Safe reverts with "GS102" if the module is already enabled. This means the `ZodiacSetupHelper.setup()` would succeed when called twice with the mock but fail with a real Safe.

**Recommendation**: Add a duplicate check to the mock for realistic testing.

---

### I-04: MockDelay Has No Access Control on Administrative Functions

**Severity**: Informational
**Contract**: `MockDelay.sol` lines 112-125

**Description**: `setTxCooldown`, `setTxExpiration`, and `setTxNonce` have no access control in the mock. In the real Zodiac Delay module, these are restricted to the owner (the Safe). The integration test calls `delay.setTxNonce(1)` directly (line 139 of Integration.t.sol) without pranking as the Safe.

**Impact**: Tests do not verify that only the Safe can configure Delay parameters or cancel transactions.

**Recommendation**: Add `require(msg.sender == avatar, "only owner")` to administrative functions in the mock.

---

### I-05: Test Helper Uses Non-Standard userOpHash Computation

**Severity**: Informational
**Contract**: `Safe4337RolesModule.t.sol` lines 372-377, `Integration.t.sol` lines 287-288

**Description**: The test helpers compute `userOpHash` as:
```solidity
userOpHash = keccak256(abi.encode("userOpHash", block.timestamp, callData_));
```

The real EntryPoint computes it as:
```solidity
keccak256(abi.encode(
    keccak256(pack(userOp)),
    address(entryPoint),
    block.chainid
))
```

The test hash includes `block.timestamp` and a magic string but does not include the EntryPoint address or chain ID. This means the tests do not verify that the signature scheme works with real EntryPoint-generated hashes.

**Recommendation**: Use the real EntryPoint hash computation in tests, or at minimum test with a mock EntryPoint that generates realistic hashes.

---

## Per-Contract Analysis

### Safe4337RolesModule (DEEP REVIEW)

#### Validation Phase

| Check | Status | Details |
|-------|--------|---------|
| ECDSA recovery math | PASS | Correct EIP-2 s-value upper bound check. Correct v-value check (27 or 28). Correct calldataload offsets for r, s, v extraction. |
| Malformed signature handling | PASS | Returns `address(0)` for wrong length (not 65 bytes), high-s, or invalid v. `address(0)` lookup returns inactive config. Returns `SIG_VALIDATION_FAILED`. |
| Zero-address ecrecover edge case | PASS | If `ecrecover` returns `address(0)`, the operator lookup finds `operators[address(0)].active == false`, returning failure. |
| Operator lookup | PASS | Checks `config.active` flag. Inactive and non-existent operators both return `active == false`. |
| Transient storage write | CRITICAL | See C-01. Operator stored but never cleared. |
| Return value format | HIGH | See H-03. Bare 0/1 without time bounds. |
| Prefund handling | LOW | See L-05. Return value ignored. |
| Signing scheme | HIGH | See H-01. Uses eth_sign prefix, non-standard. |
| Replay protection | HIGH | See H-02. No module-level chain ID check. |

**Assembly analysis** (lines 200-204):
```solidity
assembly {
    r := calldataload(signature.offset)
    s := calldataload(add(signature.offset, 0x20))
    v := byte(0, calldataload(add(signature.offset, 0x40)))
}
```
- `calldataload(signature.offset)` reads 32 bytes at the signature start -> r (correct)
- `calldataload(signature.offset + 0x20)` reads 32 bytes at offset 32 -> s (correct)
- `calldataload(signature.offset + 0x40)` reads 32 bytes at offset 64 -> byte(0, ...) extracts the first byte -> v (correct for 65-byte signatures where v is 1 byte)

No overflow risk in the assembly: `add(signature.offset, 0x20)` and `add(signature.offset, 0x40)` are safe since `signature.offset` is a calldata offset that cannot overflow in practice.

#### Execution Phase

| Check | Status | Details |
|-------|--------|---------|
| Operator read from transient storage | CRITICAL | See C-01, C-02. No clearing, no hash binding. |
| Calldata decoding | PASS | `abi.decode(callData[4:], (address, uint256, bytes))` correctly skips the 4-byte selector. Reverts on callData < 4 bytes. |
| Calldata boundary: empty inner data | PASS | `abi.decode` handles empty `bytes` correctly. |
| Roles module call | PASS | Correct interface usage. `shouldRevert=true` provides descriptive errors. |
| Operation type | LOW | See L-04. Hardcoded to 0 (Call). No DelegateCall. |
| Return value handling | INFO | See I-02. Dead code after Roles call with `shouldRevert=true`. |
| Value forwarding | PASS | `value` from decoded calldata is passed to Roles. The module itself does not forward ETH (Roles handles this through the Safe). |

**Calldata decoding edge cases**:
- `callData.length == 4` (selector only): `abi.decode` will attempt to decode `(address, uint256, bytes)` from zero bytes, which reverts. Safe.
- `callData.length == 3`: Caught by `if (callData.length < 4) revert ExecutionFailed()`. Safe.
- Very large calldata: No explicit limit, but gas costs scale linearly. Not a vulnerability.

#### Operator Management

| Check | Status | Details |
|-------|--------|---------|
| addOperator access control | PASS | `onlySafe` modifier. |
| addOperator zero address | PASS | Explicit check. |
| addOperator duplicate | PASS | Checks `active` flag. |
| addOperator re-addition | PASS | Removed operators (active=false) can be re-added. |
| removeOperator access control | PASS | `onlySafe` modifier. |
| removeOperator non-existent | PASS | Checks `active` flag, reverts for inactive. |
| Race condition with pending UserOps | MEDIUM | See M-03. |
| Batch operations | NOT SUPPORTED | No bulk add/remove. Minor UX limitation. |
| roleKey update | NOT SUPPORTED | To change an operator's roleKey, must remove and re-add. Acceptable. |

#### Transient Storage Security

| Check | Status | Details |
|-------|--------|---------|
| Slot uniqueness | LOW | See L-01. Hardcoded value does not match claimed derivation. |
| Cross-UserOp leakage | CRITICAL | See C-01. Single slot, never cleared, overwritten by each validation. |
| Simulation safety | CONCERN | If `validateUserOp` runs in simulation without `executeUserOp`, operator remains in transient storage until end of eth_call. If multiple simulations run in one eth_call, leakage occurs. |
| External spoofing | SAFE | Only EntryPoint can call `validateUserOp` (which writes) and `executeUserOp` (which reads). No external spoofing vector. |
| EIP-1153 revert semantics | CONCERN | `tstore` in `validateUserOp` is in the outer call context of the EntryPoint. Even if `executeUserOp` reverts in a sub-call, the `tstore` from validation persists. This is by design but means the operator identity outlives a failed execution. |
| Multiple transient slots needed | YES | To safely handle batched UserOps, a single slot is insufficient. Either clear after use or use a keyed approach. |

### ZodiacSetupHelper

| Check | Status | Details |
|-------|--------|---------|
| Access control | CONCERN | See M-02. Must be delegatecalled from Safe. |
| Array length validation | PASS | `operators.length != roleKeys.length` reverts. |
| Module enable order | INFO | Enables Roles, Delay, Safe4337RolesModule on Safe. Order does not matter for `enableModule`. |
| Missing member assignment | CRITICAL GAP | Does not call `roles.assignRoles(safe4337RolesModule, [roleKey], [true])`. Real Roles module will reject all calls from the bridge module. |
| Idempotency | NO | Real Safe reverts on duplicate `enableModule`. Cannot be called twice. |
| Missing Delay module chain setup | GAP | Does not configure Roles to forward through Delay. Does not enable Roles as a module on Delay. The chain topology must be configured separately. |

---

## Zodiac Integration Security

### Module Chain Analysis

The intended chain:
```
EntryPoint -> Safe4337RolesModule -> Roles -> Delay -> Safe
```

For this chain to function correctly, the following configuration is required:

| Step | Configuration | Done in Code? | Impact if Missing |
|------|--------------|---------------|-------------------|
| 1 | Enable Delay module on Safe | ZodiacSetupHelper (partial) | Delay cannot call Safe |
| 2 | Enable Roles module on Delay | NOT DONE | Roles cannot queue to Delay |
| 3 | Assign Safe4337RolesModule as member of roleKey in Roles | NOT DONE | All execTransactionWithRole calls fail |
| 4 | Set Roles avatar/target to Delay module | NOT DONE | Roles forwards to wrong target |
| 5 | Set Delay avatar to Safe | MockDelay constructor only | Delay executes on wrong target |
| 6 | Enable Safe4337RolesModule on Safe | ZodiacSetupHelper | Module cannot call Safe |
| 7 | Configure Delay cooldown and expiration | ZodiacSetupHelper (partial) | Depends on who can call setters |

**Steps 2, 3, and 4 are critical gaps.** The integration tests work because MockRoles and MockDelay are manually configured in `setUp()` to work around these gaps. A production deployment following only the `ZodiacSetupHelper.setup()` flow would fail.

### Potential Attack: Malicious Roles Module Swap

If a Safe owner is compromised, they can call `setRolesModule(maliciousRoles)` to point the bridge at a Roles module that approves everything:

```solidity
contract MaliciousRoles {
    function execTransactionWithRole(...) external returns (bool) {
        return true; // Approve everything
    }
}
```

Combined with a Delay module that has zero cooldown, this effectively gives the attacker full control through the operator channel. The defense is that `setRolesModule` requires `onlySafe`, so the Safe's threshold of owners must be compromised.

Since no event is emitted (see L-02), this attack would be difficult to detect off-chain.

### Module Chain Order Attack

If the chain is misconfigured (e.g., Delay is skipped):
```
Safe4337RolesModule -> Roles -> Safe (bypassing Delay)
```

The Roles module would execute directly on the Safe without timelock. This is a configuration error, not a code vulnerability, but the module does not verify the chain topology. There is no way for the module to confirm that the Delay module is in the chain.

### Mock vs Real Behavior Gaps

| Feature | Mock Behavior | Real Zodiac Behavior | Gap Severity |
|---------|--------------|---------------------|--------------|
| Member assignment in Roles | NOT CHECKED | Required for every execTransactionWithRole | **CRITICAL** |
| Parameter conditions (18+ operators) | Only target+selector checked | Full condition tree with AND/OR, comparisons, bitmasks | HIGH |
| Roles module avatar/target | Custom `targetModule` field | `IAvatar(avatar).execTransactionFromModule()` | MEDIUM |
| Delay module owner checks | No access control on setters | Owner-only for setTxCooldown, setTxExpiration, setTxNonce | MEDIUM |
| Safe enableModule duplicate | Silently succeeds | Reverts with GS102 | LOW |
| Delay hash computation | `keccak256(abi.encode(to, value, keccak256(data), operation))` | May differ in real implementation | MEDIUM |
| Delay executeNextTx access | Public, anyone can call | Public in real module too (anyone can execute after cooldown) | NONE |
| Roles scoping model | Flat: target -> selector -> allowed | Hierarchical: target -> function -> parameter conditions | HIGH |

---

## Test Coverage Assessment

### Coverage Summary

| Category | Unit | Integration | Edge Case | Fuzz |
|----------|------|------------|-----------|------|
| Operator add | YES | YES | YES (zero, duplicate) | NO |
| Operator remove | YES | YES | YES (inactive, non-existent) | NO |
| Operator re-add after removal | NO | NO | NO | NO |
| Signature validation (valid) | YES | YES | NO | NO |
| Signature validation (invalid) | YES | NO | YES (bad length, removed op) | NO |
| Signature validation (malformed) | NO | NO | NO | NO |
| EntryPoint access control | YES | implicit | N/A | NO |
| Safe access control | YES | implicit | N/A | NO |
| Roles permission pass | YES | YES | N/A | NO |
| Roles permission reject | YES | YES | N/A | NO |
| Delay queue | NO unit | YES | N/A | NO |
| Delay cooldown | NO unit | YES | YES (before/after) | NO |
| Delay expiration | NO unit | YES | YES | NO |
| Delay cancellation | NO unit | YES | YES | NO |
| Multiple queued ops | NO | YES | PARTIAL | NO |
| Transient storage batch | NO | NO | NO | NO |
| Prefund ETH transfer | YES | NO | NO (insufficient) | NO |
| Config changes (setRoles/Delay) | NO | NO | NO | NO |
| DelegateCall operations | NO | NO | NO | NO |
| Calldata edge cases | NO | NO | NO | NO |
| Cross-chain replay | NO | NO | NO | NO |
| receive() ETH | NO | NO | NO | NO |

### Critical Missing Tests

1. **Batched UserOp transient storage behavior** -- The most critical gap. No test verifies what happens when multiple UserOps from different operators are processed in a single `handleOps` call.

2. **Operator re-registration** -- No test verifies that a removed operator can be re-added with a different roleKey.

3. **Configuration mutation** -- No test for `setRolesModule` or `setDelayModule`. An attacker swapping the Roles module is untested.

4. **Signature fuzz testing** -- No fuzzing of the `_recoverSigner` function with random bytes, which could reveal edge cases in ECDSA recovery.

5. **Calldata boundary conditions** -- No test for empty calldata, selector-only calldata, or extremely large calldata.

---

## Recommendations

### Priority 1: Critical Fixes (Must Fix Before Any Deployment)

| ID | Finding | Fix |
|----|---------|-----|
| C-01 | Transient storage never cleared | Clear after reading in `executeUserOp`. Store and verify `userOpHash` binding. |
| C-02 | No calldata integrity check | Store calldata hash in transient storage during validation, verify in execution. |
| M-05 | Missing member assignment in Roles | Add `roles.assignRoles(moduleAddress, [roleKey], [true])` to setup flow. |

### Priority 2: High Fixes (Must Fix Before Production)

| ID | Finding | Fix |
|----|---------|-----|
| H-01 | eth_sign prefix non-standard | Switch to raw `userOpHash` signing or EIP-712 typed data. |
| H-02 | No cross-chain replay protection | Add `block.chainid` check in `validateUserOp`. |
| H-03 | No time-bounded validation | Support `validAfter`/`validUntil` packing per ERC-4337 spec. |

### Priority 3: Medium Fixes (Should Fix)

| ID | Finding | Fix |
|----|---------|-----|
| M-01 | Zero address allowed for rolesModule/delayModule | Add zero checks in constructor. |
| M-02 | ZodiacSetupHelper access model ambiguous | Add delegatecall check or restructure. |
| M-03 | Operator removal race condition | Document or add two-phase removal. |
| M-04 | Unused delayModule variable | Remove or use in execution path. |

### Priority 4: Testing Improvements

1. Add integration test with batched UserOps from different operators to expose C-01.
2. Add fork tests against real Zodiac Roles v2 and Delay module deployments.
3. Add fuzz tests for `_recoverSigner`.
4. Add tests for configuration mutation functions.
5. Add member assignment checks to MockRoles.
6. Add access control to MockDelay administrative functions.

### Priority 5: Architectural Considerations

1. **Emergency pause**: Add a circuit breaker that the Safe can activate to immediately disable all operator execution.
2. **Module chain verification**: Add a view function that queries the Roles module's target, the Delay module's enabled modules, etc., to verify the chain is correctly configured.
3. **Upgradeability documentation**: Since the module is not upgradeable (constructor-based), document the procedure for disabling and replacing the module if a vulnerability is found.
4. **Per-operator nonce**: Consider an independent nonce per operator to prevent stale UserOp submission.
5. **Batch execution safety**: If batched UserOps are a requirement, redesign the transient storage mechanism to use a keyed mapping approach (e.g., `tstore(keccak256(OPERATOR_SLOT, userOpHash), operator)`), though this is complex with EIP-1153.
