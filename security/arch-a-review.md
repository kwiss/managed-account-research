# Security Review: Arch A (EIP-7702 + ERC-7579)

**Reviewer**: Internal Security Review
**Date**: 2026-02-11
**Scope**: All Solidity source files in `prototypes/arch-a-7702/src/` and `prototypes/arch-a-7702/test/`
**Commit**: Pre-release prototype
**Methodology**: Manual line-by-line review of all source contracts, interface contracts, and test files. Adversarial threat modeling against each access path.

---

## Executive Summary

**Overall Risk Rating: HIGH**

The prototype demonstrates a well-structured architecture with clean separation of concerns (hooks, policies, interfaces). However, the audit identified **3 critical**, **6 high**, **5 medium**, **5 low**, and **6 informational** findings. The most severe issues center on: (1) completely permissionless `initializePolicy()` functions in all policy contracts, enabling arbitrary configuration overwrite by any address; (2) the permissionless `queueOperation()` enabling queue griefing and front-running; (3) the immediate selector bypass being target-agnostic, allowing 4-byte collision attacks to bypass the timelock for arbitrary contracts; and (4) several owner-impersonation and reentrancy vectors in the timelock hook. The HookMultiPlexer's `msg.sender` context break makes it fundamentally incompatible with the timelock hook as currently designed.

No single contract is production-ready. The prototype is useful for demonstrating architecture patterns, but every contract requires significant hardening before deployment to any network holding real value.

### Findings Summary

| Severity       | Count |
|----------------|-------|
| **CRITICAL**   | 3     |
| **HIGH**       | 6     |
| **MEDIUM**     | 5     |
| **LOW**        | 5     |
| **INFORMATIONAL** | 6  |

---

## Critical Findings

### C-01: `initializePolicy()` Is Fully Permissionless -- All Three Policy Contracts

**Severity**: CRITICAL
**Location**: `UniswapSwapPolicy.sol:51`, `AaveSupplyPolicy.sol:45`, `ApprovalPolicy.sol:36`
**Status**: Open

**Description**: All three policy contracts expose a public `initializePolicy()` function with zero access control. Any address can call it at any time to overwrite the entire policy configuration for any account. There is no restriction on the caller, no check for prior initialization, and no owner validation. The function simply overwrites `_configs[account]` and sets `_initialized[account] = true`.

For `UniswapSwapPolicy`, the attacker can change:
- `allowedTokensIn` / `allowedTokensOut` (add malicious tokens)
- `requiredRecipient` (redirect swap output to attacker)
- `allowedFeeTiers` (enable arbitrarily high fees)
- `dailyVolumeLimit` (set to `type(uint256).max` to remove rate limiting)

For `AaveSupplyPolicy`, the attacker can change:
- `allowedAssets` (add any asset)
- `requiredOnBehalfOf` (redirect deposits to attacker's address)
- `maxSupplyPerTx` / `dailySupplyLimit` (remove all limits)

For `ApprovalPolicy`, the attacker can change:
- `allowedSpenders` (approve arbitrary contracts to spend the account's tokens)
- `maxApproval` (set to `type(uint256).max` to enable unlimited approvals)

**Attack Scenario**:
1. Owner configures `UniswapSwapPolicy` for their managed account with `requiredRecipient = accountAddress` and strict token allowlists.
2. Attacker calls `policy.initializePolicy(victimAccount, maliciousConfig)` where `maliciousConfig.requiredRecipient = attackerAddress`.
3. The next operator swap passes policy validation but sends swap output to the attacker.
4. For `ApprovalPolicy`: attacker sets `allowedSpenders = [attackerContract]` and `maxApproval = type(uint256).max`, then the operator (or attacker as operator) approves the attacker to spend all tokens.

**Proof of Concept**:
```solidity
// Attacker can do this at any time:
UniswapSwapPolicy.SwapConfig memory malicious = UniswapSwapPolicy.SwapConfig({
    allowedTokensIn: allTokens,
    allowedTokensOut: allTokens,
    requiredRecipient: attackerAddress, // <-- redirect funds
    allowedFeeTiers: allTiers,
    dailyVolumeLimit: type(uint256).max
});
policy.initializePolicy(victimAccount, malicious);
```

**Impact**: Complete fund theft. Any managed account's policy configuration can be silently overwritten to redirect funds, approve arbitrary spenders, or remove all rate limits.

**Recommendation**:
1. Require `msg.sender == account` (the account contract itself must call `initializePolicy`).
2. Add a re-initialization guard: `require(!_initialized[account], "AlreadyInitialized")`.
3. For updates, create a separate `updatePolicy()` function restricted to the account with the owner going through the hook chain.

---

### C-02: `queueOperation()` Is Fully Permissionless -- ManagedAccountTimelockHook

**Severity**: CRITICAL
**Location**: `ManagedAccountTimelockHook.sol:62-86`
**Status**: Open

**Description**: The `queueOperation()` function can be called by any address, for any initialized account, with any operator address and any operation data. There is no validation that the caller is the operator, the account, the owner, or any authorized party. The interface NatSpec explicitly states: "Anyone can call this."

The only guard is `_owners[account] != address(0)` (account must be initialized), which is a trivially met condition for any active account.

**Attack Scenario 1 -- Queue Stuffing / Timing Grief**:
1. Operator wants to execute `swap(WETH, USDC, 1 ETH)` at time T.
2. Attacker monitors and calls `queueOperation(victimAccount, operator, 0, swapCalldata)` at time T-10 hours.
3. Since `AlreadyQueued` prevents re-queuing the same hash, the operator's queue entry is set with the attacker's chosen timing.
4. The execution window may elapse before the operator notices, or the cooldown starts at an inconvenient time.

**Attack Scenario 2 -- Front-Running Queue Submissions**:
1. Operator submits a `queueOperation` transaction to the mempool.
2. Attacker sees it, front-runs with the identical call (same parameters) but at an earlier block.
3. The operator's transaction reverts with `AlreadyQueued`.
4. The attacker controls when the cooldown timer started.

**Attack Scenario 3 -- Denial of Service via Permissionless Queuing**:
1. Attacker queues operations for all anticipated operator actions.
2. Since each operation hash is deterministic and unique, the operator cannot re-queue.
3. The attacker can grief every expected operation.

**Impact**: Denial of service on the queue system. Operators lose control over timing of their operations. Queue can be griefed to make the system unusable without direct fund theft (but combined with C-03, timing manipulation could enable exploits).

**Recommendation**: Restrict `queueOperation()` to authorized callers:
```solidity
function queueOperation(...) external {
    require(msg.sender == operator || msg.sender == account, "Unauthorized");
    // ... existing logic
}
```

---

### C-03: Immediate Selector Bypass Is Target-Agnostic -- Hardcoded `address(0)` in `preCheck()`

**Severity**: CRITICAL
**Location**: `ManagedAccountTimelockHook.sol:104-111`
**Status**: Open

**Description**: In `preCheck()`, the immediate selector lookup uses a hardcoded `address(0)` as the target:

```solidity
bytes32 selectorKey = keccak256(abi.encodePacked(address(0), selector));
if (_immediateSelectors[account][selectorKey]) {
    return abi.encode(false, bytes32(0)); // Bypass timelock
}
```

This means if selector `0x414bf389` (Uniswap `exactInputSingle`) is whitelisted as immediate, then **any contract** with a function matching that 4-byte selector can be called by an operator without going through the timelock.

Critically, 4-byte selector collisions are trivial to engineer. An attacker can deploy a contract with a function whose selector collides with a whitelisted selector but performs an arbitrary malicious action.

Meanwhile, `setImmediateSelector()` at line 165-169 properly takes a `target` parameter and hashes `keccak256(abi.encodePacked(target, selector))`. But the Integration test at line 103 calls `account.whitelistSelector(address(0), SWAP_SELECTOR, true)` -- always passing `address(0)` as the target. This creates a mismatch: the storage supports per-target whitelisting, but the `preCheck()` lookup path only checks `address(0)`, making per-target whitelisting useless if the preCheck never extracts the actual target.

**Root Cause**: The hook's `preCheck()` function receives `msgData` (the calldata for the account's `execute()` function), not the inner target+calldata. The hook has no way to extract the target address from the execution data without knowing the account's execution encoding format. This is a fundamental architectural gap.

**Attack Scenario**:
1. Owner whitelists `exactInputSingle` (0x414bf389) as immediate for their account.
2. Attacker deploys: `contract Evil { function evil_collision_414bf389() external { /* drain ETH */ } }` where the function selector is crafted to be `0x414bf389`.
3. Operator (or a compromised session key) calls the Evil contract through the account with this selector.
4. The timelock hook sees the whitelisted selector and allows immediate execution without any delay.
5. Funds are drained.

**Impact**: Complete timelock bypass for any operation whose calldata starts with a whitelisted 4-byte selector. The timelock hook provides zero protection for any whitelisted selector.

**Recommendation**:
1. The `preCheck()` must extract the target address from `msgData`. This requires knowing the account's execution encoding format (e.g., for ERC-7579 single execution: `abi.decode(msgData[4:], (address, uint256, bytes))`).
2. Then check: `keccak256(abi.encodePacked(target, selector_of_inner_calldata))`.
3. If the target cannot be extracted (e.g., batch execution mode), the immediate selector bypass should be disabled for batch operations.
4. Until this is fixed, do not use the immediate selector whitelist in production.

---

## High Findings

### H-01: `onInstall()` Can Be Called Multiple Times -- Overwrites Owner Without Guard

**Severity**: HIGH
**Location**: `ManagedAccountTimelockHook.sol:39-45`
**Status**: Open

**Description**: The `onInstall()` function unconditionally overwrites `_owners[account]` and `_configs[account]` without checking whether the account is already initialized. If the account contract allows re-installation of modules (which is permitted by many ERC-7579 implementations), or if a compromised executor module can trigger `onInstall`, the owner can be silently replaced.

```solidity
function onInstall(bytes calldata data) external override(IERC7579Module) {
    (address owner, uint128 cooldown, uint128 expiration) = abi.decode(data, (address, uint128, uint128));
    address account = msg.sender;
    _owners[account] = owner; // Unconditional overwrite
    _configs[account] = TimelockConfig(cooldown, expiration);
}
```

**Attack Scenario**:
1. Account installs timelock hook with `owner = legitimateOwner, cooldown = 1 hour`.
2. A compromised executor module calls `account.installModule(MODULE_TYPE_HOOK, timelockHookAddr, abi.encode(attacker, 0, 1))` -- but wait, `setTimelockConfig` rejects zero cooldown. However, `onInstall` has NO such validation. Setting `cooldown = 1` (1 second) effectively removes the timelock.
3. The attacker is now the "owner" who bypasses the timelock entirely, and the cooldown is 1 second.

**Additional Issue**: `onInstall()` does NOT validate that `cooldown > 0` or `expiration > 0`, unlike `setTimelockConfig()`. This means a zero cooldown can be set during installation, making operations immediately executable.

**Impact**: Complete ownership takeover of the timelock. The attacker becomes the owner and can execute any operation without delay.

**Recommendation**:
```solidity
function onInstall(bytes calldata data) external override {
    require(_owners[msg.sender] == address(0), "AlreadyInstalled");
    (address owner, uint128 cooldown, uint128 expiration) = abi.decode(data, (address, uint128, uint128));
    require(owner != address(0), "InvalidOwner");
    require(cooldown > 0 && expiration > 0, "InvalidConfig");
    _owners[msg.sender] = owner;
    _configs[msg.sender] = TimelockConfig(cooldown, expiration);
}
```

---

### H-02: `onUninstall()` Does Not Clear Queue Entries or Immediate Selectors -- Stale State Persists

**Severity**: HIGH
**Location**: `ManagedAccountTimelockHook.sol:48-52`
**Status**: Open

**Description**: When the hook is uninstalled, only `_owners` and `_configs` are deleted:

```solidity
function onUninstall(bytes calldata) external override(IERC7579Module) {
    address account = msg.sender;
    delete _owners[account];
    delete _configs[account];
    // _queue and _immediateSelectors are NOT cleared
}
```

The `_queue` entries and `_immediateSelectors` mappings persist in storage. If the module is later reinstalled:
- Previously queued operations remain in the queue with their original timing. Under the new configuration (potentially different cooldown/expiration), these stale entries could become immediately executable.
- Previously whitelisted immediate selectors remain active, potentially bypassing the new owner's intended configuration.

**Attack Scenario**:
1. Account uses timelock hook with `cooldown = 24 hours`.
2. Operator queues an operation. Owner decides to uninstall and reinstall the hook with `cooldown = 7 days` for tighter security.
3. After reinstall, the old queue entry's `executeAfter` is still based on the old 24-hour cooldown. If the 24 hours have passed, the operator can execute immediately despite the new 7-day policy.

**Impact**: Security parameter downgrades are not retroactive. Operations queued under lax parameters survive reconfiguration to stricter parameters.

**Recommendation**: Implement a generation/nonce counter that increments on every install. Include the generation in the exec hash so all prior queue entries become invalid. For immediate selectors, maintain a list of active keys to clear, or reset them via the nonce approach.

---

### H-03: HookMultiPlexer `msg.sender` Context Break -- Fundamentally Incompatible with TimelockHook

**Severity**: HIGH
**Location**: `HookMultiPlexer.sol:74-75`
**Status**: Open

**Description**: When the HookMultiPlexer calls sub-hooks, the sub-hook sees `msg.sender = HookMultiPlexer_address`, not the original account:

```solidity
// In HookMultiPlexer.preCheck():
allHookData[i] = IERC7579Hook(hooks[i]).preCheck(msgSender, msgValue, msgData);
// hooks[i] sees msg.sender = address(HookMultiPlexer), NOT the account
```

The ManagedAccountTimelockHook uses `msg.sender` to identify the account:
```solidity
// In ManagedAccountTimelockHook.preCheck():
address account = msg.sender; // This will be HookMultiPlexer, not the real account
address owner = _owners[account]; // Looks up owner for HookMultiPlexer address, not the account
```

Since the HookMultiPlexer was never installed as an "account" on the timelock hook, `_owners[multiplexerAddress]` returns `address(0)`. The owner check `if (msgSender == owner)` becomes `if (msgSender == address(0))`, which is false for any real address. The operator path then computes an exec hash for the wrong "account" (the multiplexer's address).

**Compounding Risk**: If someone were to call `onInstall` from the multiplexer's address to "register" it as an account, the owner/config would be shared across ALL accounts using that multiplexer. This would be a shared security domain -- any account's owner could cancel any other account's operations.

The Integration test at lines 209-212 explicitly acknowledges this issue but does not test the broken path, leaving the bug undocumented in test failures.

**Impact**: The timelock hook is completely non-functional when composed through the HookMultiPlexer. Either all operations revert (no owner set for multiplexer) or the security model breaks (shared state across accounts).

**Recommendation**:
1. Short term: Document that HookMultiPlexer MUST NOT be used with ManagedAccountTimelockHook. These are incompatible components.
2. Long term: Redesign the hook interface to accept an explicit `account` parameter, or use `delegatecall` for sub-hook invocation (requires careful security analysis), or implement an account-context-forwarding pattern.

---

### H-04: No Chain ID in `computeExecHash` -- Cross-Chain Replay of Queue Entries

**Severity**: HIGH
**Location**: `ManagedAccountTimelockHook.sol:209-216`
**Status**: Open

**Description**: The exec hash computation does not include `block.chainid`:

```solidity
function _computeExecHash(
    address account, address msgSender, uint256 msgValue, bytes calldata msgData
) internal pure returns (bytes32) {
    return keccak256(abi.encode(account, msgSender, msgValue, msgData));
}
```

With CREATE2 or deterministic deployments (common for both accounts and modules), the same addresses can exist on multiple chains. An operation queued on chain A would have the same hash on chain B. If the same hook contract is deployed at the same address on both chains (via CREATE2), the queue states are separate (different chain = different storage), but the hash matching means an operation queued on one chain could be pre-computed and queued on another by a griefing attacker.

More concretely: if the queue check is done off-chain (e.g., a relayer checks whether an exec hash is queued), the relayer could be tricked into submitting a cross-chain operation.

**Impact**: Queue hash collisions across chains. In a multi-chain deployment, operations on one chain could interfere with monitoring/relaying logic for another chain.

**Recommendation**:
```solidity
return keccak256(abi.encode(block.chainid, account, msgSender, msgValue, msgData));
```

---

### H-05: Owner Bypass When `_owners[account] == address(0)` for Uninitialized Account -- `preCheck` Silently Allows Bypass

**Severity**: HIGH
**Location**: `ManagedAccountTimelockHook.sol:96-102`
**Status**: Open

**Description**: If `preCheck()` is called for an account that was never initialized (or was uninstalled), `_owners[account]` returns `address(0)`. The owner check becomes:

```solidity
address owner = _owners[account]; // address(0)
if (msgSender == owner) {         // if (msgSender == address(0))
    return abi.encode(true, bytes32(0)); // BYPASS
}
```

This will never trigger for a normal address (no one calls from `address(0)`). However, the function does NOT revert for uninitialized accounts. It proceeds to the immediate selector check and then the queue check. If there happens to be a stale queue entry (from a previous install/uninstall cycle per H-02), the operation could execute against an uninitialized account configuration.

More importantly, the `preCheck()` function lacks the `NotInitialized` guard that `queueOperation()` has. This inconsistency means the preCheck path has weaker access control than the queue path.

**Impact**: Operations can potentially pass `preCheck` for uninitialized accounts if stale state exists, or if immediate selectors were set from a previous installation. The behavior is undefined and dangerous.

**Recommendation**: Add an initialization check at the top of `preCheck()`:
```solidity
if (_owners[account] == address(0)) revert NotInitialized();
```

---

### H-06: Reentrancy in `preCheck()` -- Queue Deletion Before Return

**Severity**: HIGH
**Location**: `ManagedAccountTimelockHook.sol:131-135`
**Status**: Open

**Description**: In `preCheck()`, the queue entry is deleted before the function returns. The function is called by the account contract, which then proceeds to execute the actual operation. The flow is:

1. Account calls `hook.preCheck(operator, value, data)` -- queue entry deleted.
2. Account executes the actual operation (e.g., swap on Uniswap).
3. Account calls `hook.postCheck(hookData)`.

Between steps 1 and 2, the queue entry is already deleted. If the account's execution in step 2 somehow calls back into the timelock hook (e.g., through a callback from the DeFi protocol, or if the operator's action triggers a fallback that re-enters the hook), the queue entry is gone but the execution has not completed.

While `preCheck` does delete-before-return (which is the correct CEI pattern for the queue), the concern is that `postCheck` does nothing meaningful. If the actual execution fails (reverts) but `preCheck` already cleaned up the queue, the queue entry is permanently consumed without the operation actually executing. This depends on whether the account wraps preCheck + execute + postCheck in a single transaction (it should, but this is not enforced by the hook).

**Impact**: If the account implementation does not atomically wrap preCheck + execute + postCheck in a single transaction, a reverting execution consumes the queue entry permanently. The operator must re-queue and wait for the full cooldown again.

**Recommendation**:
1. Document that the account MUST execute preCheck, execute, and postCheck atomically within a single transaction.
2. Consider moving the queue deletion to `postCheck` instead of `preCheck`, so the entry is only consumed after successful execution. This would require passing the execHash through hookData and validating it in postCheck.
3. If deletion must remain in preCheck (for reentrancy protection), add a "pending execution" flag that postCheck validates.

---

## Medium Findings

### M-01: Daily Volume Tracking Uses Fixed Day Boundaries -- Double-Spend at Midnight

**Severity**: MEDIUM
**Location**: `UniswapSwapPolicy.sol:121`, `AaveSupplyPolicy.sol:100`
**Status**: Open

**Description**: Daily volume tracking uses `block.timestamp / 1 days` as the day identifier, creating a hard boundary every 86400 seconds from the Unix epoch. An operator can exploit this by executing operations just before and just after the boundary:

- At timestamp `86400 * N - 1` (23:59:59 UTC): use the full daily limit.
- At timestamp `86400 * N` (00:00:00 UTC, 1 second later): the volume resets, use the full daily limit again.

This effectively doubles the throughput in a 2-second window.

On Ethereum, validators have ~12 seconds of timestamp manipulation ability. On L2s, the sequencer has even more control. A colluding validator/sequencer could deliberately place transactions at advantageous boundaries.

**Impact**: Operators can achieve 2x the intended daily volume by timing operations around the day boundary. In absolute worst case, this could drain 2x the expected daily limit in seconds.

**Recommendation**:
1. Implement a rolling 24-hour window using a circular buffer or linked list of recent operations.
2. Alternatively, accept this as a known trade-off and set daily limits at 50% of the actual intended limit to account for the 2x worst case.

---

### M-02: `addHook()` and `removeHook()` Lack Proper Access Control in HookMultiPlexer

**Severity**: MEDIUM
**Location**: `HookMultiPlexer.sol:98-121`
**Status**: Open

**Description**: The `addHook()` and `removeHook()` functions use `msg.sender` as the account key. While this means only the caller can modify their own hook list, the caller in the ERC-7579 context is the account contract. If an operator can trigger the account to call `multiplexer.addHook(maliciousHook)` or `multiplexer.removeHook(timelockHook)`, the hook composition is compromised.

The key question is: does the account's execution framework route `addHook`/`removeHook` calls through the hook chain? If so, the timelock would protect these calls. But if these functions can be called through a module installation path or an executor module that bypasses hooks, the protection is absent.

Additionally, `removeHook()` uses swap-and-pop for array removal (line 114), which changes the ordering of remaining hooks. Since preCheck iterates forward and postCheck iterates in reverse, changing the order could affect hook execution semantics if hooks have ordering dependencies.

**Impact**: Potential for hook composition tampering if the account's execution model allows operators to call multiplexer management functions. Hook reordering on removal could cause unexpected behavior.

**Recommendation**: Restrict `addHook`/`removeHook` to only be callable during the `onInstall`/`onUninstall` lifecycle, or implement explicit access control (e.g., require the caller is the account AND the caller is the owner per the timelock hook's owner mapping).

---

### M-03: Policy `checkAction()` Is State-Modifying -- Vulnerable to Simulation Consumption

**Severity**: MEDIUM
**Location**: `UniswapSwapPolicy.sol:60-75`, `AaveSupplyPolicy.sol:54-75`
**Status**: Open

**Description**: The `checkAction()` function in UniswapSwapPolicy and AaveSupplyPolicy modifies state by incrementing the daily volume/supply counter on every call. In the ERC-4337 context, `validateUserOp` is simulated by bundlers before inclusion. If `checkAction()` is called during this simulation phase, the volume counter is incremented without an actual execution occurring.

Even in non-4337 contexts, if `checkAction()` is called and the outer transaction subsequently reverts (but the policy call was in a try/catch or sub-call that doesn't revert), the volume is consumed without actual execution.

More concretely: if `checkAction` is called within the hook's `preCheck`, and preCheck succeeds, but the actual DeFi operation fails, the daily volume is permanently consumed. The operator's daily limit is reduced by a phantom operation.

**Impact**: Daily volume can be consumed by failed operations, simulations, or gas estimation calls. This can DoS an operator by exhausting their daily limit without any actual operations succeeding.

**Recommendation**:
1. Make `checkAction()` a `view` function that only validates without modifying state.
2. Track volume in a separate `recordAction()` function called only after confirmed successful execution (e.g., in the `postCheck` phase).
3. Or document that `checkAction()` MUST only be called within an atomic transaction that also performs the actual operation.

---

### M-04: Unsafe `uint128` to `uint48` Truncation in Timelock Timestamp Computation

**Severity**: MEDIUM
**Location**: `ManagedAccountTimelockHook.sol:75-77`
**Status**: Open

**Description**: Cooldown and expiration are stored as `uint128` but silently truncated to `uint48` when computing queue timestamps:

```solidity
uint48 now_ = uint48(block.timestamp);
uint48 executeAfter = now_ + uint48(config.cooldownPeriod);
uint48 expiresAt = executeAfter + uint48(config.expirationPeriod);
```

If `config.cooldownPeriod` is set to a value exceeding `2^48 - 1` (281,474,976,710,655), the `uint48()` cast silently truncates the value. Since `setTimelockConfig()` accepts `uint128` values (up to ~3.4 * 10^38) without upper bound validation, a misconfigured or maliciously set cooldown could truncate to a small number.

Example: `cooldownPeriod = 2^48 + 1` truncates to `uint48(1)`, making operations executable after just 1 second instead of the intended ~8,900 years.

Additionally, the arithmetic `now_ + uint48(config.cooldownPeriod)` could overflow `uint48` if `now_` + truncated cooldown exceeds `2^48 - 1`. Since Solidity 0.8+ has checked arithmetic, this would revert, but the revert happens during `queueOperation()`, not during `setTimelockConfig()`, providing a poor user experience.

**Impact**: A misconfigured cooldown period can truncate to a trivially small value, making the timelock effectively useless. In the worst case, this is exploitable if combined with H-01 (re-installation with malicious config).

**Recommendation**:
1. Validate in `onInstall()` and `setTimelockConfig()` that both values fit within `uint48` range.
2. Consider using `uint48` for the config fields themselves to prevent the type mismatch.
3. Add upper bound checks (e.g., max cooldown of 30 days, max expiration of 7 days).

---

### M-05: `preCheck()` Does Not Validate That `msgSender == entry.operator` -- Any Address Can Execute a Queued Operation

**Severity**: MEDIUM
**Location**: `ManagedAccountTimelockHook.sol:113-135`
**Status**: Open

**Description**: When an operation is queued, the `operator` address is stored in the queue entry. However, during `preCheck()`, the exec hash computation uses `msgSender` (the actual caller), not the stored `entry.operator`. Since the hash includes `msgSender`, a different caller would produce a different hash and would not match the queue entry. This provides implicit validation.

However, if the same operation parameters are queued for a specific operator, and a different address calls `preCheck` with `msgSender = operator` (possible if the account's execution framework allows specifying the `msgSender` parameter independently), the hash would match. The `preCheck` does not cross-check that `msgSender == entry.operator` after finding the queue entry.

In the current architecture, `msg.sender` to preCheck is the account, and `msgSender` is a parameter provided by the account contract. If the account contract can be tricked into passing a different `msgSender` than the actual transaction originator, the operator field validation is bypassed.

**Impact**: If the account's execution framework does not correctly set `msgSender` to the actual transaction originator, queue entries can be executed by unauthorized parties.

**Recommendation**: Add an explicit check after finding the queue entry:
```solidity
if (entry.operator != msgSender) revert UnauthorizedOperator(msgSender, entry.operator);
```
This provides defense-in-depth regardless of the account implementation.

---

## Low Findings

### L-01: `postCheck()` Is a No-Op -- No Post-Execution Validation

**Severity**: LOW
**Location**: `ManagedAccountTimelockHook.sol:139-142`
**Status**: Open

**Description**: The `postCheck()` function does nothing meaningful:

```solidity
function postCheck(bytes calldata hookData) external override(IERC7579Hook) {
    (bool isOwnerOrImmediate,) = abi.decode(hookData, (bool, bytes32));
    if (isOwnerOrImmediate) return;
    // falls through -- no action for operator path either
}
```

Even for the operator path (when `isOwnerOrImmediate` is false), the function simply falls through without any post-execution validation. This means the timelock hook has no ability to:
- Verify that the operation actually succeeded.
- Check that the account's balance didn't decrease beyond expected bounds.
- Enforce post-execution invariants.

**Impact**: No post-execution safety net. If a queued operation has an unintended side effect, there is no mechanism to catch it.

**Recommendation**: Either implement meaningful post-execution checks (e.g., balance invariant assertions) or simplify to an empty body to save gas and avoid misleading code.

---

### L-02: `_isInArray()` Linear Search Is O(n) and Unbounded

**Severity**: LOW
**Location**: `UniswapSwapPolicy.sol:130-135`, `AaveSupplyPolicy.sol:109-114`, `ApprovalPolicy.sol:78-83`
**Status**: Open

**Description**: All three policy contracts use linear search over dynamic arrays for allowlist lookups. The arrays have no size bound. If an admin configures a very large allowlist (hundreds or thousands of addresses), the gas cost of `checkAction()` could exceed the block gas limit.

This also creates a DoS vector: since `initializePolicy()` is permissionless (C-01), an attacker could initialize a policy with an enormous allowlist, causing all subsequent `checkAction()` calls to run out of gas.

**Impact**: Gas griefing or DoS. Even with C-01 fixed, an admin misconfiguration could make the policy unusable.

**Recommendation**: Use `mapping(address => bool)` for O(1) lookups. If enumeration is needed, maintain both a mapping and a bounded array.

---

### L-03: No Event Emission for Owner Setting in `onInstall()`

**Severity**: LOW
**Location**: `ManagedAccountTimelockHook.sol:39-45`
**Status**: Open

**Description**: While `TimelockConfigured` is emitted during `onInstall()`, there is no event for the owner address being set. Off-chain monitoring systems cannot track ownership changes through events alone.

**Recommendation**: Add `emit OwnerSet(account, owner)` in `onInstall()` and define the corresponding event.

---

### L-04: Expired Queue Entries Block Re-Queuing of Identical Operations

**Severity**: LOW
**Location**: `ManagedAccountTimelockHook.sol:72, 121-124`
**Status**: Open

**Description**: When an operation expires, the queue entry is deleted only inside `preCheck()` (line 123). But `preCheck()` reverts after deletion (line 124). If no one calls `preCheck()` for an expired operation, the entry persists with `exists = true`.

The operator cannot re-queue the same operation because `queueOperation()` checks `entry.exists` and reverts with `AlreadyQueued`. The operator's only options are:
1. Have someone call `preCheck()` for the expired operation (which reverts but does clean up the entry via the revert + state change -- however, since it reverts, the deletion is rolled back).
2. Wait... indefinitely. The entry is permanently stuck.

Actually, on closer inspection, the `delete _queue[account][execHash]` at line 123 is followed by a `revert` at line 124. Since Solidity reverts roll back ALL state changes in the current call, the deletion is NOT persisted. **The expired entry can never be cleaned up through the `preCheck()` path.**

This means once an operation expires, its queue entry is permanently stuck, and the operator can never queue an identical operation again.

**Impact**: Permanent denial of service for specific operation hashes after expiration. The operator must change some parameter (even by 1 wei) to get a different hash.

**Recommendation**:
1. Move the delete before the revert will not work (revert rolls back state). Instead, add a dedicated `clearExpired(address account, bytes32 execHash)` function.
2. Or restructure: don't revert on expiration in preCheck; instead, delete and return a special hookData value that causes postCheck to revert, ensuring the operation doesn't execute but the cleanup persists.

---

### L-05: `onInstall()` Does Not Validate `owner != address(0)`

**Severity**: LOW
**Location**: `ManagedAccountTimelockHook.sol:39-45`
**Status**: Open

**Description**: If `onInstall` is called with `owner = address(0)`, the account is "initialized" (the `_owners` mapping has a non-default entry... except `address(0)` IS the default). This means:
- `_owners[account]` returns `address(0)`, which is the same as an uninitialized account.
- The `onlyAccount` modifier passes because `_owners[msg.sender] == address(0)` is false -- wait, actually `address(0)` equals the default, so `onlyAccount` would revert with `OnlyAccount()`.
- `queueOperation` would revert with `NotInitialized` because `_owners[account] == address(0)`.

So setting `owner = address(0)` effectively creates a broken state: the config is set but the account is treated as uninitialized by all guards.

**Impact**: Misconfiguration leads to a broken account that can neither be used nor properly uninstalled (since `onUninstall` does not have the `onlyAccount` check -- it just deletes state, so uninstall works). Low severity because the state is recoverable via reinstall.

**Recommendation**: Add `require(owner != address(0), "InvalidOwner")` in `onInstall()`.

---

## Informational

### I-01: No Nonce in Queue Hash -- Cannot Queue Identical Operations in Parallel

**Severity**: INFORMATIONAL

**Description**: The exec hash is deterministic based on `(account, operator, value, calldata)`. If an operator wants to execute the exact same operation twice (e.g., two identical swaps), they cannot queue both simultaneously. They must wait for the first to execute or expire before queuing the second.

**Recommendation**: Add a sequential nonce per account to the hash computation.

---

### I-02: Policy Contracts Use Manual ABI Decoding Instead of `abi.decode()`

**Severity**: INFORMATIONAL

**Description**: Policy contracts manually slice calldata bytes (e.g., `address(bytes20(params[12:32]))`) instead of using Solidity's built-in `abi.decode()`. The manual approach:
- Is more gas-efficient (avoids copying to memory).
- Is more fragile (no validation of padding bytes).
- Silently ignores non-zero padding in the first 12 bytes of address-type parameters. An attacker could craft calldata with non-zero padding that decodes to the same address but represents semantically different data.

For the current use case (validating standard ABI-encoded function calls), manual decoding works correctly. But it's error-prone for maintenance.

**Recommendation**: Consider using `abi.decode()` for clarity and safety, accepting the minor gas cost increase.

---

### I-03: No Module Registry or Version Checking

**Severity**: INFORMATIONAL

**Description**: There is no mechanism to verify that installed modules are from a trusted registry, are a known version, or have been audited. Any contract can be installed as a module if the account contract permits it.

**Recommendation**: Integrate with ERC-7484 (Module Registry) for production deployment.

---

### I-04: `setTimelockConfig()` Does Not Validate Upper Bounds

**Severity**: INFORMATIONAL

**Description**: While zero values are rejected, there is no upper bound on cooldown or expiration periods. Setting `cooldownPeriod = type(uint128).max` would make the system permanently unusable for operators (operations can never become executable).

**Recommendation**: Add reasonable upper bounds (e.g., `cooldown <= 30 days`, `expiration <= 30 days`).

---

### I-05: `HookMultiPlexer.postCheck()` Array Length Mismatch Is Not Validated

**Severity**: INFORMATIONAL
**Location**: `HookMultiPlexer.sol:82-93`

**Description**: In `postCheck()`, the function decodes `hookData` into `allHookData` and iterates over hooks in reverse. If the number of hooks has changed between `preCheck()` and `postCheck()` (e.g., a hook was added or removed during execution), the lengths of `hooks` and `allHookData` will differ. This could cause:
- Array index out-of-bounds if hooks were added.
- Skipped postChecks if hooks were removed.
- Mismatched hookData passed to the wrong hook.

```solidity
function postCheck(bytes calldata hookData) external override(IERC7579Hook) {
    address[] storage hooks = _hooks[account]; // Current length (may have changed)
    uint256 len = hooks.length;
    bytes[] memory allHookData = abi.decode(hookData, (bytes[])); // Length from preCheck time
    for (uint256 i = len; i > 0; --i) {
        IERC7579Hook(hooks[i - 1]).postCheck(allHookData[i - 1]); // Potential mismatch
    }
}
```

**Impact**: If hooks are modified between preCheck and postCheck within the same transaction, the postCheck behavior is undefined. In practice, modifying hooks during execution would be unusual, but it's not prevented.

**Recommendation**: Validate `allHookData.length == hooks.length` at the start of `postCheck`, or store the hook list snapshot in hookData.

---

### I-06: Test Coverage Gaps

**Severity**: INFORMATIONAL

**Description**: The test suite covers the primary happy paths and several error cases but has significant gaps in adversarial testing. See the Test Coverage Assessment section below.

---

## Per-Contract Analysis

### ManagedAccountTimelockHook

**Risk Rating**: HIGH (3 Critical references, 4 High, 2 Medium, 3 Low findings)

**Architecture**: The hook acts as a singleton contract that stores per-account configuration in mappings keyed by `msg.sender` (the account address). This is the standard ERC-7579 module pattern.

**Positive Aspects**:
- Clean separation between owner and operator execution paths.
- Queue entries are cleaned up after execution (preventing replay).
- Expiration mechanism prevents indefinitely executable operations.
- `onlyAccount` modifier provides basic access control for admin functions.
- `AlreadyQueued` prevents double-queuing the same operation.

**Critical Issues**:
- C-02: Anyone can queue operations for any account/operator combination.
- C-03: Immediate selector bypass ignores target address, enabling 4-byte collision attacks.
- H-01: No re-installation guard; owner can be overwritten.
- H-02: Stale state survives uninstall/reinstall cycles.
- H-05: No initialization check in preCheck; undefined behavior for uninitialized accounts.
- H-06: Queue entry consumed even if execution reverts (non-atomic preCheck).
- L-04: Expired entries permanently block re-queuing (revert rolls back delete).

**Reentrancy Assessment**: The contract follows checks-effects-interactions partially. In `preCheck()`, the queue deletion (effect) happens before the return (but there are no external calls after deletion, so reentrancy during preCheck itself is not exploitable). However, the reentrancy risk exists between preCheck and the actual execution in the account contract.

**Storage Collision Assessment**: No risk. Each mapping is keyed by account address, providing proper isolation. The singleton pattern is correctly implemented.

### UniswapSwapPolicy

**Risk Rating**: CRITICAL (due to C-01)

**Architecture**: Singleton policy contract with per-account configuration and daily volume tracking.

**Positive Aspects**:
- Validates all critical swap parameters: tokenIn, tokenOut, fee tier, recipient, and amount.
- Daily volume tracking provides rate limiting.
- Minimum calldata length check (`data.length < 260`) prevents short-calldata attacks.
- ETH value transfers are explicitly rejected.

**Critical Issues**:
- C-01: Permissionless `initializePolicy()` allows complete configuration overwrite.
- M-01: Day boundary manipulation enables 2x daily limit exploitation.
- M-03: State-modifying `checkAction()` vulnerable to simulation consumption.
- L-02: Linear search for allowlists is unbounded.

**ABI Decoding Assessment**: The manual calldata decoding at lines 97-102 is correct for standard ABI-encoded `ExactInputSingleParams`. However:
- The minimum length check of 260 bytes is correct for the 8-parameter struct (4 + 8*32 = 260).
- The byte offset calculations are correct: params[12:32] extracts the address from bytes 12-31 of each 32-byte word.
- The fee extraction at params[93:96] correctly gets the uint24 from the last 3 bytes of the 64-95 word.

### AaveSupplyPolicy

**Risk Rating**: CRITICAL (due to C-01)

**Architecture**: Identical singleton pattern to UniswapSwapPolicy.

**Positive Aspects**:
- Validates asset, amount, onBehalfOf, and daily limits.
- Per-transaction maximum prevents large single operations.
- Minimum calldata length check of 132 bytes is correct for `supply(address,uint256,address,uint16)` (4 + 4*32 = 132).

**Critical Issues**:
- C-01: Permissionless `initializePolicy()`.
- M-01, M-03, L-02: Same issues as UniswapSwapPolicy.

**ABI Decoding Assessment**: The decoding at lines 68-70 is correct for standard ABI encoding. The `referralCode` (uint16) parameter is decoded but not used, which is intentional (referral codes don't need validation).

### ApprovalPolicy

**Risk Rating**: CRITICAL (due to C-01)

**Architecture**: Identical singleton pattern. Simpler than the other policies (no daily tracking).

**Positive Aspects**:
- Validates spender allowlist and maximum approval amount.
- Prevents unlimited approvals to unknown contracts.
- Minimum calldata length check of 68 bytes is correct for `approve(address,uint256)` (4 + 2*32 = 68).

**Critical Issues**:
- C-01: Permissionless `initializePolicy()`.
- L-02: Linear search.

**Note**: ApprovalPolicy does NOT have daily volume tracking, so M-01 and M-03 do not apply.

### HookMultiPlexer

**Risk Rating**: HIGH (due to H-03)

**Architecture**: Singleton multiplexer that composes multiple ERC-7579 hooks. Forward iteration for preCheck, reverse iteration for postCheck (onion model).

**Positive Aspects**:
- Clean composition pattern with proper hookData aggregation.
- Duplicate hook prevention via `_hookExists` mapping.
- Proper array-based storage with swap-and-pop removal.

**Critical Issues**:
- H-03: `msg.sender` context break makes it fundamentally incompatible with the timelock hook.
- M-02: Hook management functions lack explicit access control.
- I-05: No length validation between preCheck and postCheck hook arrays.

**Ordering Concern**: The swap-and-pop removal at line 114 changes hook ordering. If hook A must execute before hook B (ordering dependency), removing hook C from between them could break the expected order. This is a design trade-off for gas efficiency but should be documented.

---

## Test Coverage Assessment

### Well-Tested Paths

| Contract | Path | Test |
|----------|------|------|
| TimelockHook | Owner bypass | `test_ownerBypass` |
| TimelockHook | Operator queue + execute | `test_operatorQueue`, `test_operatorExecuteAfterCooldown` |
| TimelockHook | Cooldown enforcement | `test_operatorCooldownNotElapsed_reverts` |
| TimelockHook | Expiration enforcement | `test_operatorExpiredOperation` |
| TimelockHook | Owner cancellation | `test_ownerCancel` |
| TimelockHook | Immediate selector bypass | `test_immediateSelectorBypass` |
| TimelockHook | Config update | `test_configureTimelock` |
| TimelockHook | Double-queue prevention | `test_doubleQueue_reverts` |
| TimelockHook | Uninitialized queue revert | `test_queueForUninitializedAccount_reverts` |
| TimelockHook | Access control | `test_onlyAccountCanCancel`, `test_onlyAccountCanConfigure` |
| UniswapPolicy | Valid swap | `test_validSwap` |
| UniswapPolicy | All invalid params | 5 revert tests |
| UniswapPolicy | Daily volume + reset | `test_dailyVolumeExceeded_reverts`, `test_dailyVolumeResetsAfterOneDay` |
| AavePolicy | Valid supply | `test_validSupply` |
| AavePolicy | All invalid params | 4 revert tests |
| ApprovalPolicy | Valid approval | `test_validApproval` |
| ApprovalPolicy | Invalid params | 3 revert tests |
| Integration | Full lifecycle | `test_fullOperatorFlow` |
| Integration | Owner bypass | `test_ownerBypassesTimelock` |
| Integration | Multiplexer install | `test_multiplexerComposition` |

### Critical Paths NOT Tested

1. **C-01 exploitation**: No test showing `initializePolicy()` can be called by an attacker to overwrite config.
2. **C-02 exploitation**: No test showing `queueOperation()` called by a random (non-operator) address.
3. **C-03 exploitation**: No test showing a different target with the same selector bypassing the timelock.
4. **H-01 exploitation**: No test for `onInstall()` being called twice (owner overwrite).
5. **H-02 exploitation**: No test for stale state after `onUninstall()` + `onInstall()` cycle.
6. **H-05 exploitation**: No test for `preCheck()` on an uninitialized account.
7. **H-06 scenario**: No test for queue entry consumption when execution fails.
8. **L-04 verification**: No test proving expired entries block re-queuing permanently.
9. **Cross-chain hash**: No test verifying hash uniqueness across chains.
10. **Malformed calldata**: No test for policy contracts receiving calldata with extra bytes, short bytes (below minimum), or non-standard ABI encoding.
11. **Zero-address owner**: No test for `onInstall(address(0), cooldown, expiration)`.
12. **Gas exhaustion**: No test for large allowlist arrays causing out-of-gas in policy contracts.
13. **HookMultiPlexer with timelock**: The integration test acknowledges the msg.sender issue but does not test the broken path to prove it fails.
14. **Hook removal reordering**: No test for hook order change after removal.
15. **Concurrent queue entries**: No test for multiple different operations queued simultaneously for the same account.
16. **`postCheck` with malformed hookData**: No test for what happens if postCheck receives incorrectly encoded data.

---

## Recommendations

### Priority 1 -- Must Fix Before ANY Deployment (Including Testnet)

| # | Finding | Fix |
|---|---------|-----|
| 1 | C-01 | Add `require(msg.sender == account)` to all `initializePolicy()` functions. |
| 2 | C-02 | Add `require(msg.sender == operator || msg.sender == account)` to `queueOperation()`. |
| 3 | C-03 | Extract target address from msgData in `preCheck()` and use it for selector key lookup, OR remove immediate selector feature entirely. |
| 4 | H-01 | Add `require(_owners[msg.sender] == address(0))` guard and validate config in `onInstall()`. |
| 5 | H-05 | Add `require(_owners[account] != address(0))` at the top of `preCheck()`. |

### Priority 2 -- Should Fix Before Mainnet

| # | Finding | Fix |
|---|---------|-----|
| 6 | H-02 | Implement generation counter or clear all state in `onUninstall()`. |
| 7 | H-04 | Include `block.chainid` in `_computeExecHash()`. |
| 8 | H-06 | Move queue deletion to `postCheck()` or implement atomic execution guarantee. |
| 9 | M-04 | Validate `uint48` bounds in `onInstall()` and `setTimelockConfig()`. |
| 10 | M-05 | Add `require(entry.operator == msgSender)` check in `preCheck()`. |
| 11 | L-04 | Add `clearExpired()` function for garbage collection. |
| 12 | L-05 | Validate `owner != address(0)` in `onInstall()`. |

### Priority 3 -- Should Fix Before Production

| # | Finding | Fix |
|---|---------|-----|
| 13 | H-03 | Document HookMultiPlexer incompatibility with TimelockHook, or redesign. |
| 14 | M-01 | Implement rolling 24-hour window or accept/document the 2x boundary issue. |
| 15 | M-02 | Add access control to `addHook()`/`removeHook()`. |
| 16 | M-03 | Make `checkAction()` view-only; track volume separately after confirmed execution. |
| 17 | L-02 | Use mappings instead of arrays for allowlist lookups. |

### Priority 4 -- Nice to Have

| # | Finding | Fix |
|---|---------|-----|
| 18 | I-01 | Add nonce to exec hash for parallel identical operations. |
| 19 | I-02 | Consider `abi.decode()` for policy calldata parsing. |
| 20 | I-03 | Integrate ERC-7484 Module Registry. |
| 21 | I-04 | Add upper bounds for cooldown/expiration. |
| 22 | I-05 | Validate hook array length consistency in multiplexer postCheck. |
| 23 | L-03 | Emit owner-set event in `onInstall()`. |

---

## Appendix A: Threat Model

### Actors

| Actor | Capability | Trust Level |
|-------|-----------|-------------|
| **Owner** | Full control over account. Sets policies, installs modules, cancels operations. | Trusted |
| **Operator** | Executes whitelisted DeFi operations. Restricted by policies and timelock. | Semi-trusted |
| **External Attacker** | Can call any public function on any contract. Cannot impersonate addresses. | Untrusted |
| **Validator/Miner** | Can manipulate block.timestamp within ~12 seconds. Can reorder/censor transactions. | Untrusted |
| **Bundler** | Simulates UserOperations. Can choose which operations to include. | Untrusted |

### Trust Assumptions

1. The ERC-7579 account contract correctly sets `msgSender` to the actual transaction originator.
2. The account contract calls `preCheck()` and `postCheck()` atomically with the execution.
3. The account contract prevents operators from calling module management functions (install/uninstall).
4. The policy contracts are called within the same transaction as the actual DeFi operation.

### Broken Assumptions

- Assumption 1 is not verifiable from the hook's perspective (see M-05).
- Assumption 2 is not enforced by the hook (see H-06).
- Assumption 3 is not enforced by the hook or policies (see C-01, H-01, M-02).
- Assumption 4 is not enforced by the policies (see M-03).

---

## Appendix B: Severity Definitions

| Severity | Definition |
|---|---|
| **CRITICAL** | Direct path to fund loss, complete permission bypass, or permanent DoS. Exploitable by any external actor with no special conditions beyond a standard transaction. |
| **HIGH** | Permission escalation, ownership compromise, security model invalidation, or significant degradation of core security guarantees. May require specific conditions (e.g., compromised executor, reinstallation event). |
| **MEDIUM** | Operational issues, edge cases that degrade security guarantees, boundary condition exploits, or conditions that lead to unexpected/undocumented behavior. Require specific timing or configuration. |
| **LOW** | Minor issues, gas inefficiencies, missing best practices, or issues with minimal direct security impact. Recoverable or unlikely in practice. |
| **INFORMATIONAL** | Suggestions for improvement, documentation gaps, design considerations, or issues relevant only to production readiness. |
