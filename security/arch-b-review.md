# Security Review: Arch B (Safe + ERC-7579)

**Date:** 2026-02-11
**Reviewer:** Internal Security Review
**Scope:** All Solidity source files in `prototypes/arch-b-safe7579/src/` and `prototypes/arch-b-safe7579/test/`
**Solidity Version:** ^0.8.24
**Framework:** Foundry

---

## Executive Summary

The Arch B prototype implements a delegated smart account system on top of Safe + Safe7579 Adapter + ERC-7579 modules. The architecture comprises 6 custom contracts: a timelock hook (`ManagedAccountTimelockHook`), a hook composer (`HookMultiPlexer`), 3 DeFi policy contracts (`UniswapSwapPolicy`, `AaveSupplyPolicy`, `ApprovalPolicy`), and a deployment factory (`ManagedAccountSafeFactory`).

The design intent is sound: owners retain full custody while operators must queue time-delayed operations that are validated against per-account policies. However, this audit identifies **2 critical**, **6 high**, **7 medium**, and **6 low** severity findings, plus informational observations. The most dangerous issues center around:

1. A completely open `queueOperation()` function that allows anyone to queue operations or grief legitimate users (C-01).
2. A factory deployment flow that produces a dead-on-arrival timelock hook because `address(0)` is passed as `safeAccount` (H-02), combined with an encoding mismatch between the factory and the `HookMultiPlexer` (H-05).
3. Unprotected policy `checkAction()` functions that allow attackers to grief daily volume tracking without executing any actual operations (H-01).
4. A reentrancy vector in `HookMultiPlexer` that could allow a malicious sub-hook to manipulate the hook list mid-iteration (H-04).

**Overall Risk Rating: HIGH** -- Multiple independently exploitable paths exist. The system should not be deployed to any value-bearing environment without resolving at minimum all Critical and High findings.

---

## Critical Findings

### C-01: `queueOperation()` Has Zero Access Control -- Anyone Can Queue or Grief

**Severity:** CRITICAL
**Contract:** `ManagedAccountTimelockHook.sol` lines 61-74
**Status:** Confirmed

```solidity
function queueOperation(address account, address operator, bytes calldata msgData) external {
    TimelockConfig storage config = _configs[account];
    if (config.safeAccount == address(0)) revert NotInitialized();

    bytes32 opHash = keccak256(abi.encodePacked(account, operator, msgData));

    QueuedOperation storage op = _queue[account][opHash];
    if (op.queuedAt != 0 && !op.consumed) revert OperationAlreadyQueued(opHash);

    op.queuedAt = block.timestamp;
    op.consumed = false;

    emit OperationQueued(account, opHash, block.timestamp);
}
```

There is no check on `msg.sender`. Any address can call this function for any initialized `account` with any `operator` and any `msgData`.

**Attack Vector 1 -- Griefing/DoS via pre-emptive queuing:**
1. Attacker monitors the mempool for a legitimate `queueOperation` call.
2. Attacker front-runs it with `queueOperation(sameAccount, sameOperator, sameMsgData)`.
3. The legitimate call reverts with `OperationAlreadyQueued`.
4. The queued operation has `queuedAt` set to the attacker's block, not the operator's intended block.
5. If the attacker queues early enough, the cooldown window may expire before the operator realizes what happened.

**Attack Vector 2 -- Queue flooding:**
1. Attacker queues thousands of operations with varying `msgData` for a victim account.
2. While this doesn't directly compromise security (each must be independently consumed), it pollutes event logs and off-chain indexing, making it difficult for operators and owners to track legitimate operations.
3. Combined with griefing vector 1, this can continuously block legitimate operations.

**Attack Vector 3 -- Arbitrary operator impersonation:**
1. Attacker calls `queueOperation(account, arbitraryAddress, msgData)`.
2. If `arbitraryAddress` is an actual operator with a valid session key, and `msgData` matches an operation they would legitimately perform, the operation is now queued without the operator's consent.
3. The operator could unknowingly execute the pre-queued operation (since `preCheck` would see it as ready).

**Impact:** Complete denial-of-service on the queuing mechanism. Potential for operation front-running and impersonation.

**Recommendation:** Restrict `queueOperation()` so that only the account itself (called via Safe multi-sig or via an executor module) or the specified operator can queue:
```solidity
function queueOperation(address account, address operator, bytes calldata msgData) external {
    if (msg.sender != account && msg.sender != operator) revert UnauthorizedCaller();
    // ... rest of function
}
```

---

### C-02: `cancelExecution()` Has No Owner Verification -- Operators May Cancel Their Own Queued Operations

**Severity:** CRITICAL
**Contract:** `ManagedAccountTimelockHook.sol` lines 139-150

```solidity
function cancelExecution(bytes32 operationHash) external override {
    TimelockConfig storage config = _configs[msg.sender];
    if (config.safeAccount == address(0)) revert NotInitialized();

    QueuedOperation storage op = _queue[msg.sender][operationHash];
    if (op.queuedAt == 0 || op.consumed) {
        revert OperationNotFound(operationHash);
    }

    op.consumed = true;
    emit OperationCancelled(msg.sender, operationHash);
}
```

The function uses `msg.sender` as the account key. In the ERC-7579 flow, the Safe7579 adapter calls hooks with `msg.sender = Safe`. The `cancelExecution` function is therefore accessible to any operation routed through the Safe account.

**The critical issue:** If SmartSession (an executor module) can route `cancelExecution` calls through the Safe, then an operator with a valid session key could cancel operations queued by other operators or even operations they themselves queued, then re-queue with modified parameters. The NatSpec states "Only Safe owners can call this function" but the code does not verify this.

**Attack scenario:**
1. Owner queues a governance operation via timelock.
2. Operator with a SmartSession session key crafts a transaction that calls `cancelExecution(opHash)` on the timelock hook via the Safe7579 adapter.
3. If SmartSession does not explicitly block calls to the timelock hook, the operator cancels the owner's operation.

**Impact:** Operators can potentially cancel any queued operation, breaking the owner's cancellation privilege exclusivity.

**Recommendation:** The function must verify the original caller is a Safe owner:
```solidity
function cancelExecution(address msgSender, bytes32 operationHash) external override {
    TimelockConfig storage config = _configs[msg.sender];
    if (config.safeAccount == address(0)) revert NotInitialized();
    if (!ISafe(config.safeAccount).isOwner(msgSender)) revert OnlyOwner();
    // ...
}
```

Note: This requires the Safe7579 adapter or a wrapper to pass `msgSender` as a parameter, similar to how `preCheck` receives it.

---

## High Findings

### H-01: Policy `checkAction()` Has No Caller Restriction -- Daily Volume Tracking Can Be Griefed

**Severity:** HIGH
**Contracts:** `UniswapSwapPolicy.sol` line 88, `AaveSupplyPolicy.sol` line 71

All three policy contracts accept an `account` parameter externally and perform storage lookups against `_configs[account][target]`. The `UniswapSwapPolicy` and `AaveSupplyPolicy` contracts also modify storage by updating daily volume tracking:

```solidity
// UniswapSwapPolicy.sol lines 132-148
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
    vol.consumed = newConsumed; // <-- STATE MODIFICATION
}
```

**Attack:**
1. Attacker observes victim account `A` has a `SwapConfig` for router `R` with `maxDailyVolume = 10 ether`.
2. Attacker constructs valid `exactInputSingle` calldata with `amountIn = 10 ether`.
3. Attacker calls `swapPolicy.checkAction(A, R, 0, validCalldata)`.
4. The call succeeds, consuming the entire daily volume allowance.
5. When the legitimate operator tries to execute a swap, it reverts with `DailyVolumeLimitExceeded`.
6. Attacker repeats this every day at minimal gas cost.

**Impact:** Complete denial-of-service on operator swap and supply operations. The attacker never needs to hold funds, sign anything, or have any relationship with the victim account.

**Recommendation:** Add `msg.sender` verification. Only the SmartSession module (or the account itself) should be able to call `checkAction`:
```solidity
function checkAction(address account, address target, uint256 value, bytes calldata callData)
    external
    override
    returns (bool)
{
    require(msg.sender == account || msg.sender == smartSessionModule, "Unauthorized");
    // ...
}
```
This requires either passing the SmartSession address at deployment or using a registry pattern.

### H-02: Factory Passes `address(0)` as `safeAccount` -- Timelock Hook Is Dead on Arrival

**Severity:** HIGH
**Contract:** `ManagedAccountSafeFactory.sol` lines 207-208

```solidity
bytes memory timelockInitData =
    abi.encode(params.timelockCooldown, params.timelockExpiration, address(0)); // safeAccount set post-deploy
```

The `ManagedAccountTimelockHook.onInstall` stores this directly:
```solidity
_configs[msg.sender] = TimelockConfig({cooldown: cooldown, expiration: expiration, safeAccount: safeAccount});
```

After factory deployment, `_configs[safeAddress].safeAccount == address(0)`.

Every subsequent call to `preCheck`, `cancelExecution`, `setTimelockConfig`, `setImmediateSelector`, and `queueOperation` checks:
```solidity
if (config.safeAccount == address(0)) revert NotInitialized();
```

This means the entire timelock system is non-functional after deployment. The comment says "safeAccount set post-deploy" but **there is no mechanism to set it post-deploy** -- `onInstall` can only be called once during module installation, and `setTimelockConfig` only updates `cooldown` and `expiration`, not `safeAccount`.

**Impact:** The timelock hook is completely inoperative after factory deployment. All operator operations either revert (if they need the timelock) or bypass it entirely. The system loses its primary safety mechanism.

**Recommendation:** Several options:
1. **Predict the Safe address** before deployment (since CREATE2 is deterministic) and pass it in the init data.
2. **Add a `setSafeAccount` function** to the timelock hook (callable only once, by the account).
3. **Use `msg.sender` as the Safe reference** -- since the hook is always called by the Safe (via Safe7579 adapter), `msg.sender` in `preCheck` IS the Safe address:
```solidity
// In onInstall, don't require safeAccount parameter:
_configs[msg.sender] = TimelockConfig({cooldown: cooldown, expiration: expiration, safeAccount: msg.sender});
```
Option 3 is simplest and most robust.

### H-03: Operation Hash Uses `abi.encodePacked` with Variable-Length `bytes` -- Theoretical Collision Risk

**Severity:** HIGH (downgraded from original -- theoretical, but violates best practices for security-critical code)
**Contract:** `ManagedAccountTimelockHook.sol` lines 65, 101

```solidity
bytes32 opHash = keccak256(abi.encodePacked(account, operator, msgData));
```

`abi.encodePacked` concatenates the raw bytes of its arguments without length prefixes. When mixing fixed-size types (addresses = 20 bytes) with variable-length types (`bytes`), the packed encoding can produce collisions.

**Specific analysis:** Since both `account` (20 bytes) and `operator` (20 bytes) are fixed-size and appear before the variable-length `msgData`, the boundary between them is deterministic. However, the boundary between `operator` and `msgData` is ambiguous in theory: `abi.encodePacked(addr, operator1, data1)` could equal `abi.encodePacked(addr, operator2, data2)` if the last bytes of `operator1` concatenated with `data1` equals the last bytes of `operator2` concatenated with `data2`.

In practice, since Ethereum addresses are 20 bytes and their structure is determined by the keccak hash of public keys, a deliberate collision would require finding two (operator, msgData) pairs that produce the same packed encoding -- which is a hash collision problem. The risk is low but non-zero, and this is a security-critical hash.

**Impact:** Theoretical -- two different operations could share the same `opHash`, causing one to overwrite or consume the other.

**Recommendation:** Use `abi.encode` which adds length prefixes and eliminates ambiguity:
```solidity
bytes32 opHash = keccak256(abi.encode(account, operator, msgData));
```

### H-04: HookMultiPlexer Sub-Hook Calls Vulnerable to Reentrancy

**Severity:** HIGH
**Contract:** `HookMultiPlexer.sol` lines 60-81

```solidity
function preCheck(address msgSender, uint256 msgValue, bytes calldata msgData)
    external
    override
    returns (bytes memory hookData)
{
    address[] storage hooks = _hooks[msg.sender]; // storage reference
    uint256 len = hooks.length;
    // ...
    for (uint256 i = 0; i < len; i++) {
        allHookData[i] = IERC7579Hook(hooks[i]).preCheck(msgSender, msgValue, msgData);
        // ^ external call -- malicious hook can re-enter
    }
}
```

The `hooks` variable is a storage reference. If a malicious or compromised sub-hook re-enters the `HookMultiPlexer` during its `preCheck` callback, it could:

1. Call `addHook(maliciousHook)` -- increases `hooks.length`, which `len` doesn't reflect (read before the loop). The additional hook is NOT checked. But the storage array is now longer, so subsequent `postCheck` could access stale data.
2. Call `removeHook(legitimateHook)` -- uses swap-and-pop, changing `hooks[i]` for some index. Since `len` was cached, the loop runs the original count but may skip the swapped hook and check the removed hook twice (or access a now-empty slot).
3. Call `onInstall` or `onUninstall` to reset the hooks array entirely.

**Impact:** A malicious sub-hook can manipulate the hook execution flow, potentially bypassing other hooks' `preCheck` or `postCheck` validations.

**Recommendation:** Copy the hooks array to memory before iterating:
```solidity
address[] memory cachedHooks = _hooks[msg.sender];
uint256 len = cachedHooks.length;
bytes[] memory allHookData = new bytes[](len);
for (uint256 i = 0; i < len; i++) {
    allHookData[i] = IERC7579Hook(cachedHooks[i]).preCheck(msgSender, msgValue, msgData);
}
```
Additionally, consider adding OpenZeppelin's `ReentrancyGuard` to `addHook`, `removeHook`, `onInstall`, and `onUninstall`.

### H-05: Factory Init Data Encoding Mismatch with HookMultiPlexer

**Severity:** HIGH
**Contract:** `ManagedAccountSafeFactory.sol` line 209 vs `HookMultiPlexer.sol` line 42

The factory encodes hook init data as:
```solidity
bytes memory timelockInitData = abi.encode(params.timelockCooldown, params.timelockExpiration, address(0));
bytes memory hookInitData = abi.encode(timelockHook, timelockInitData);
```

This produces an encoding of `(address, bytes)`.

The `HookMultiPlexer.onInstall` expects:
```solidity
address[] memory initialHooks = abi.decode(data, (address[]));
```

This expects `(address[])`.

These ABI encodings are structurally different:
- `abi.encode(address, bytes)` starts with a 32-byte padded address + 32-byte offset to bytes data + length + data
- `abi.encode(address[])` starts with a 32-byte offset to array + 32-byte length + array elements

Attempting to decode `(address, bytes)` as `(address[])` will either revert or produce garbage data.

**Impact:** Factory-driven deployment will fail at the HookMultiPlexer initialization step. Even if the Launchpad somehow handles the mismatch, the hook would be incorrectly configured.

**Recommendation:** The factory must encode as the HookMultiPlexer expects:
```solidity
address[] memory hookAddresses = new address[](1);
hookAddresses[0] = timelockHook;
bytes memory hookInitData = abi.encode(hookAddresses);
```

### H-06: `_extractTargetAndSelector` Can Be Bypassed via Batch Execution Mode

**Severity:** HIGH
**Contract:** `ManagedAccountTimelockHook.sol` lines 208-246

The `_extractTargetAndSelector` function parses calldata assuming single execution mode (mode = bytes32(0)):
```solidity
// For single execution mode, the executionCalldata is:
// abi.encodePacked(address target (20 bytes), uint256 value (32 bytes), bytes callData)
target = address(bytes20(msgData[encodedStart:encodedStart + 20]));
```

ERC-7579 defines multiple execution modes (single, batch, delegatecall). If an operator submits an execution in batch mode, the parsing logic extracts incorrect values:
- For batch mode, the `executionCalldata` is an array of `(target, value, callData)` tuples.
- The function would parse the batch encoding as if it were a single execution, extracting the wrong target/selector.
- This could cause the immediate selector check to match an unintended selector, bypassing the timelock for operations that should require it.

**Attack scenario:**
1. Operator configures `address(0)` + `bytes4(0)` as an immediate selector (or the extraction returns these defaults for malformed data).
2. Operator submits a batch execution with a dangerous operation.
3. `_extractTargetAndSelector` misparses the batch, returns `(address(0), bytes4(0))`.
4. If immediate selector is set for `address(0)/bytes4(0)`, the operation bypasses the timelock.
5. Even without that, returning `(address(0), bytes4(0))` means the operation hash would be computed for the wrong target/selector.

**Impact:** Potential timelock bypass via execution mode manipulation.

**Recommendation:** Check the execution mode from `msgData[4:36]` and explicitly revert for unsupported modes:
```solidity
bytes32 mode = bytes32(msgData[4:36]);
if (mode != bytes32(0)) revert UnsupportedExecutionMode();
```

---

## Medium Findings

### M-01: `_extractTargetAndSelector` Silently Returns Defaults for Malformed Calldata

**Severity:** MEDIUM
**Contract:** `ManagedAccountTimelockHook.sol` lines 218-219, 226-228, 234-235

The function has three early return points that yield `(address(0), bytes4(0))`:
```solidity
if (msgData.length < 100) {
    return (address(0), bytes4(0));  // silent failure
}
// ...
if (msgData.length < dataStart + 32) {
    return (address(0), bytes4(0));  // silent failure
}
// ...
if (msgData.length < encodedStart + 52) {
    return (address(0), bytes4(0));  // silent failure
}
```

Additionally, when `dataLen <= 52` (execution calldata has no inner calldata), `selector` defaults to `bytes4(0)`.

This means ANY malformed calldata shorter than 100 bytes will check immediate selectors for `target=address(0), selector=bytes4(0)`. If an administrator ever inadvertently sets `_immediateSelectors[account][address(0)][bytes4(0)] = true`, all malformed operations bypass the timelock.

**Impact:** Potential timelock bypass if `address(0)/bytes4(0)` is configured as immediate. More practically, malformed calldata is silently accepted rather than rejected, leading to unpredictable behavior.

**Recommendation:** Revert instead of returning defaults:
```solidity
if (msgData.length < 100) revert InvalidExecutionCalldata();
```

### M-02: Miner Timestamp Manipulation Can Affect Short Cooldown Periods

**Severity:** MEDIUM
**Contract:** `ManagedAccountTimelockHook.sol` lines 110-121

```solidity
uint256 readyAt = op.queuedAt + config.cooldown;
if (block.timestamp < readyAt) {
    revert OperationNotReady(opHash, readyAt);
}
```

Ethereum validators can adjust `block.timestamp` within a bounded range (typically up to ~15 seconds into the future). For short cooldown values, this provides a small but non-zero attack surface.

More importantly, `onInstall` and `setTimelockConfig` accept any non-zero cooldown:
```solidity
if (cooldown == 0 || expiration == 0) revert InvalidTimelockConfig();
```

A cooldown of `1 second` is accepted, which is trivially bypassed by timestamp manipulation.

**Impact:** Cooldowns shorter than ~30 seconds offer negligible security. The 1-hour default in tests is safe, but the system should enforce a minimum.

**Recommendation:** Enforce a minimum cooldown (e.g., 5 minutes):
```solidity
uint256 constant MIN_COOLDOWN = 5 minutes;
if (cooldown < MIN_COOLDOWN) revert CooldownTooShort();
```

### M-03: Daily Volume Tracking Exploitable at UTC Day Boundary

**Severity:** MEDIUM
**Contracts:** `UniswapSwapPolicy.sol` lines 132-148, `AaveSupplyPolicy.sol` lines 100-116

```solidity
uint256 currentDay = block.timestamp / 1 days;
if (vol.day != currentDay) {
    vol.day = currentDay;
    vol.consumed = 0;
}
```

An operator can execute `maxDailyVolume` worth of operations at 23:59:59 UTC, then execute another `maxDailyVolume` worth at 00:00:00 UTC, effectively consuming `2x maxDailyVolume` within a 2-second window.

**Impact:** The effective daily volume limit can be doubled by timing operations around the UTC day boundary.

**Recommendation:** Use a rolling 24-hour window:
```solidity
struct VolumeWindow {
    uint256 windowStart;
    uint256 consumed;
}
// Reset if more than 24 hours have passed since windowStart
if (block.timestamp > vol.windowStart + 1 days) {
    vol.windowStart = block.timestamp;
    vol.consumed = 0;
}
```

### M-04: `removeHook` Swap-and-Pop Silently Changes Hook Execution Order

**Severity:** MEDIUM
**Contract:** `HookMultiPlexer.sol` lines 109-124

```solidity
function removeHook(address hook) external {
    address[] storage hooks = _hooks[msg.sender];
    uint256 len = hooks.length;
    for (uint256 i = 0; i < len; i++) {
        if (hooks[i] == hook) {
            hooks[i] = hooks[len - 1];
            hooks.pop();
            emit HookRemoved(msg.sender, hook);
            return;
        }
    }
    revert HookNotFound(hook);
}
```

If the hook array is `[A, B, C]` and `A` is removed, the result is `[C, B]`, not `[B, C]`. The `preCheck` iteration order changes from `A->B->C` to `C->B`, and `postCheck` (reverse) changes from `C->B->A` to `B->C`.

If hook B depends on state set by hook A's `preCheck`, or hook C's `postCheck` depends on hook B's `postCheck` running first, the behavioral change is silent and potentially security-relevant.

**Impact:** Silent semantic change in hook execution order when hooks are removed.

**Recommendation:** Use an array shift pattern (more gas but preserves order) or document that order is not guaranteed and design hooks to be order-independent.

### M-05: No Validation of `safeAccount` in `onInstall` -- Malicious Safe Reference

**Severity:** MEDIUM
**Contract:** `ManagedAccountTimelockHook.sol` lines 35-42

```solidity
function onInstall(bytes calldata data) external override {
    (uint256 cooldown, uint256 expiration, address safeAccount) = abi.decode(data, (uint256, uint256, address));
    if (cooldown == 0 || expiration == 0) revert InvalidTimelockConfig();
    _configs[msg.sender] = TimelockConfig({cooldown: cooldown, expiration: expiration, safeAccount: safeAccount});
}
```

There is no validation that `safeAccount` is actually a Safe contract, or that `msg.sender` (the installing account) is the same as or related to `safeAccount`. An attacker (or a misconfiguration) could install the hook with a malicious contract as `safeAccount`:

```solidity
contract MaliciousSafe {
    function isOwner(address) external pure returns (bool) {
        return true; // everyone is an "owner"
    }
}
```

If installed with a `MaliciousSafe` address, the `preCheck` owner bypass would trigger for ALL callers, effectively disabling the timelock.

**Impact:** If the hook is installed with a malicious `safeAccount`, the timelock is completely bypassed.

**Recommendation:** Use `msg.sender` as the safe account reference (see H-02 recommendation), or verify the `safeAccount` implements ISafe and that `msg.sender` is associated with it.

### M-06: `onUninstall` Does Not Clean Up Queue and Immediate Selectors

**Severity:** MEDIUM
**Contract:** `ManagedAccountTimelockHook.sol` lines 45-47

```solidity
function onUninstall(bytes calldata) external override {
    delete _configs[msg.sender];
}
```

Only `_configs[msg.sender]` is deleted. The `_queue[msg.sender]` and `_immediateSelectors[msg.sender]` mappings are NOT cleaned up. If the module is uninstalled and later reinstalled:

1. Old queued operations with `consumed = false` remain in the queue. If the same operation hash is computed after reinstallation, `queueOperation` would revert with `OperationAlreadyQueued`.
2. Old immediate selectors remain active. Operations that should require timelock after reinstallation might bypass it.

**Impact:** Stale state from previous installation leaks into new installation, potentially causing unexpected behavior.

**Recommendation:** Either:
1. Document that reinstallation requires different salt/parameters to avoid hash collisions.
2. Add cleanup logic (though cleaning mappings is expensive for large datasets).
3. Include a nonce in the config that invalidates old queue entries.

### M-07: `postCheck` in `HookMultiPlexer` Does Not Validate Array Length Consistency

**Severity:** MEDIUM
**Contract:** `HookMultiPlexer.sol` lines 84-97

```solidity
function postCheck(bytes calldata hookData) external override {
    address[] storage hooks = _hooks[msg.sender];
    uint256 len = hooks.length;
    if (len == 0) return;
    if (hookData.length == 0) return;
    bytes[] memory allHookData = abi.decode(hookData, (bytes[]));
    for (uint256 i = len; i > 0; i--) {
        IERC7579Hook(hooks[i - 1]).postCheck(allHookData[i - 1]);
    }
}
```

If `allHookData.length != len` (e.g., hooks were added or removed between `preCheck` and `postCheck`):
- If `allHookData.length < len`: accessing `allHookData[i - 1]` for `i > allHookData.length` causes an out-of-bounds revert.
- If `allHookData.length > len`: some hookData entries are silently ignored.

**Impact:** If hooks are modified between preCheck and postCheck (via reentrancy per H-04, or via a separate transaction in the same block), the postCheck either reverts unexpectedly or silently skips checks.

**Recommendation:** Add an explicit length check:
```solidity
require(allHookData.length == len, "Hook count mismatch");
```

---

## Low Findings

### L-01: Factory Does Not Validate Timelock Parameters

**Severity:** LOW
**Contract:** `ManagedAccountSafeFactory.sol` lines 146-148

```solidity
if (params.owners.length == 0 || params.threshold == 0 || params.threshold > params.owners.length) {
    revert InvalidParams();
}
```

No validation for `timelockCooldown` or `timelockExpiration`. A user passing `0` for either would succeed at the factory level but fail later during `onInstall`. This wastes gas and provides poor error messages.

**Recommendation:** Add:
```solidity
if (params.timelockCooldown == 0 || params.timelockExpiration == 0) revert InvalidParams();
```

### L-02: `ImmediateSelector` Field in Factory `DeploymentParams` Is Never Used

**Severity:** LOW
**Contract:** `ManagedAccountSafeFactory.sol` lines 98-108

The `DeploymentParams` struct includes `ImmediateSelector[] immediateSelectors` but `_buildSetupCalldata` never references `params.immediateSelectors`. Callers might expect this to be wired into the deployment, leading to a false sense of security (operators believe certain selectors are immediate, but they're not configured).

**Recommendation:** Either wire it into the deployment calldata or remove from the struct.

### L-03: No Events in `HookMultiPlexer` `onInstall`/`onUninstall`

**Severity:** LOW
**Contract:** `HookMultiPlexer.sol` lines 38-56

Individual hook additions emit `HookAdded`, but the overall lifecycle (`onInstall`, `onUninstall`) emits no top-level event. The `onUninstall` deletes the entire hooks array without any event, making it impossible to track module lifecycle off-chain.

**Recommendation:** Add lifecycle events.

### L-04: Policy Config Functions Have No Initialization Guard

**Severity:** LOW
**Contracts:** `UniswapSwapPolicy.sol` line 75, `AaveSupplyPolicy.sol` line 58, `ApprovalPolicy.sol` line 46

Any address can call `setSwapConfig`, `setSupplyConfig`, or `setApprovalConfig` for itself. While this is benign (configs are per-`msg.sender`), it means orphan configs can accumulate for addresses that are not part of the system.

**Recommendation:** Document this as by-design or add a registry check.

### L-05: `ApprovalPolicy.checkAction` Is `view` But `IActionPolicy` Is Not

**Severity:** LOW
**Contract:** `ApprovalPolicy.sol` line 59

`ApprovalPolicy.checkAction` is marked `view`, while `IActionPolicy.checkAction` is not (it returns `bool` without `view`/`pure`). While Solidity allows a `view` function to override a non-`view` interface function, this means calling `checkAction` on the `IActionPolicy` interface type will not benefit from `view` optimizations.

**Recommendation:** Consider making `IActionPolicy.checkAction` explicitly `view` or documenting why it's non-`view`.

### L-06: No Duplicate Owner Check in Factory Parameters

**Severity:** LOW
**Contract:** `ManagedAccountSafeFactory.sol` line 146

The factory checks `params.owners.length > 0` and `params.threshold <= params.owners.length` but does not check for duplicate owners. If `owners = [A, A]` with `threshold = 2`, the Safe deployment might succeed but only require 1 actual signer (since owner A appears twice but Safe's `setupOwners` may deduplicate or fail).

**Recommendation:** Check for duplicates or document that the Safe's own validation handles this.

---

## Informational

### I-01: Prototype Uses Locally Defined Interfaces

All interfaces (`ISafe`, `ISafe7579`, `IERC7579Hook`, `IActionPolicy`, etc.) are defined locally. These may drift from canonical versions. For production, import from official packages.

### I-02: No Reentrancy Guards on State-Modifying Functions

`UniswapSwapPolicy.checkAction` and `AaveSupplyPolicy.checkAction` modify storage (daily volume tracking) without reentrancy guards. While reentrancy into these functions is unlikely in normal flow, defense-in-depth suggests adding guards.

### I-03: Magic Numbers in `_extractTargetAndSelector`

Offsets 100, 36, 68, 52, 56 correspond to ERC-7579 execute calldata layout but should be named constants:
```solidity
uint256 constant EXECUTE_SELECTOR_SIZE = 4;
uint256 constant MODE_SIZE = 32;
uint256 constant MIN_EXECUTE_CALLDATA = 100;
// etc.
```

### I-04: `queueOperation` Can Re-Queue Consumed Operations

After an operation is consumed (executed, cancelled, or expired), `op.consumed = true` but `op.queuedAt != 0`. The check:
```solidity
if (op.queuedAt != 0 && !op.consumed) revert OperationAlreadyQueued(opHash);
```

This means a consumed operation CAN be re-queued (since `op.consumed == true`, the condition `!op.consumed` is false, so the revert is skipped). This is likely intentional (allowing the same operation to be queued again after consumption) but should be explicitly documented.

### I-05: No Support for ERC-7579 Execute via DelegateCall Mode

The `_extractTargetAndSelector` function assumes `CALL` mode. If the Safe7579 adapter sends a `DELEGATECALL` mode execution, the target extraction would still work but the security implications are different (delegatecall to target runs in the Safe's context). The timelock should probably reject delegatecall mode entirely.

### I-06: Test Mocks Are Simplified

The `MockSafe`, `MockSafeProxyFactory`, and `MockSafe7579Launchpad` in tests are highly simplified. They do not replicate actual Safe behavior (e.g., multi-sig threshold enforcement, owner management, module linked list). This means tests validate the custom contracts in isolation but may miss integration issues with real Safe infrastructure.

---

## Per-Contract Analysis

### ManagedAccountTimelockHook

| Aspect | Assessment | Findings |
|--------|-----------|----------|
| Access Control | **CRITICAL** | `queueOperation()` has no caller restriction (C-01). `cancelExecution()` has no owner check (C-02). |
| Reentrancy | LOW | `preCheck` calls external `ISafe.isOwner()` but state is read-only at that point. |
| Integer Safety | SAFE | Solidity 0.8+ overflow protection. `readyAt = op.queuedAt + config.cooldown` and `expiresAt = readyAt + config.expiration` are safe unless values are astronomically large (uint256 overflow at 0.8+ reverts). |
| Timestamp | MEDIUM | Relies on `block.timestamp` for all timing logic (M-02). |
| Storage Isolation | SAFE | Per-account via `msg.sender`-keyed mappings. |
| Initialization | HIGH | `safeAccount` not validated (M-05), `address(0)` from factory (H-02). |
| Hash Security | HIGH | `abi.encodePacked` with variable-length data (H-03). |
| Cleanup | MEDIUM | `onUninstall` leaves stale queue and immediate selectors (M-06). |
| Batch Support | HIGH | No batch execution mode handling (H-06). |

### ManagedAccountSafeFactory

| Aspect | Assessment | Findings |
|--------|-----------|----------|
| Deployment Flow | HIGH | `address(0)` safeAccount makes timelock DOA (H-02). |
| Encoding | HIGH | Init data mismatch with HookMultiPlexer (H-05). |
| CREATE2 Prediction | SAFE | Standard CREATE2 formula with salt derived from setupCalldata hash. |
| Front-running | LOW | Attacker front-running deployment deploys the same Safe (same owners/config). Griefing only. |
| Parameter Validation | LOW | Missing timelock param checks (L-01), unused immediateSelectors (L-02). |
| Immutables | SAFE | All set in constructor, cannot be changed post-deployment. |
| Upgradeability Risk | INFO | If referenced modules (smartSession, hookMultiplexer, etc.) at the stored addresses are proxies and get upgraded, the factory still points to the same addresses but the behavior may change. Not a direct vulnerability but an operational concern. |

### UniswapSwapPolicy

| Aspect | Assessment | Findings |
|--------|-----------|----------|
| Calldata Decoding | SAFE | Correct ABI offsets for `exactInputSingle(ExactInputSingleParams)`. |
| Access Control | **HIGH** | No caller restriction, volume tracking griefable (H-01). |
| Daily Volume | MEDIUM | Day boundary exploit (M-03). |
| Parameter Checks | SAFE | tokenIn, tokenOut, recipient, feeTier, amountIn all validated correctly. |
| Edge Cases | INFO | `amountOutMinimum` and `sqrtPriceLimitX96` are not validated -- operators can set these to zero, accepting maximum slippage. This is by design (policy focuses on what assets flow where, not execution quality). |

### AaveSupplyPolicy

| Aspect | Assessment | Findings |
|--------|-----------|----------|
| Calldata Decoding | SAFE | Correct ABI offsets for `supply(address,uint256,address,uint16)`. |
| Access Control | **HIGH** | Same as UniswapSwapPolicy (H-01). |
| Daily Volume | MEDIUM | Same day boundary issue (M-03). |
| Parameter Checks | SAFE | Asset and onBehalfOf properly validated. |
| Edge Cases | INFO | `referralCode` (uint16) is not validated -- operators can set any referral code. Low risk. |

### ApprovalPolicy

| Aspect | Assessment | Findings |
|--------|-----------|----------|
| Calldata Decoding | SAFE | Correct ABI offsets for `approve(address,uint256)`. |
| Access Control | LOW | `checkAction` is `view`, no state modification possible via external calls. |
| Parameter Checks | SAFE | Spender and amount validated. |
| ERC-20 Race | INFO | The classic `approve` race condition (existing allowance > 0) is outside this policy's scope -- it validates the approve call parameters, not the token state. |
| Unlimited Approvals | INFO | If `maxAmount = 0`, unlimited approvals are allowed. An operator could approve `type(uint256).max` to a whitelisted spender. If the spender is compromised later, all funds are at risk. Consider logging/monitoring max approvals. |

### HookMultiPlexer

| Aspect | Assessment | Findings |
|--------|-----------|----------|
| Reentrancy | **HIGH** | External calls during iteration use storage reference (H-04). |
| Hook Order | MEDIUM | Swap-and-pop changes order (M-04). |
| postCheck Consistency | MEDIUM | No length validation (M-07). |
| Bounds | SAFE | `MAX_HOOKS = 16` caps array size and gas cost. |
| Zero Address | SAFE | Validated in `_addHook`. |
| Duplicates | SAFE | Checked via linear scan in `_addHook`. |
| DoS | LOW | Linear scan for duplicate check is O(n) but bounded by MAX_HOOKS=16. |

---

## Safe-Specific Security Analysis

### Safe7579 Adapter Trust Boundary

The trust model in this architecture:

```
User/Operator --> Bundler --> EntryPoint --> Safe (via Safe7579 Adapter)
                                              |
                                              +--> Safe7579 Adapter
                                                    |
                                                    +--> Validator (OwnableValidator) - verifies signatures
                                                    |
                                                    +--> Hook (HookMultiPlexer -> TimelockHook) - enforces timelock
                                                    |
                                                    +--> Executor (SmartSession) - manages session keys + policies
```

**Critical trust assumption:** The Safe7579 adapter MUST invoke the hook's `preCheck` before every execution and `postCheck` after. If the adapter has a code path that skips hook invocation, the entire timelock system is bypassed. This review does not audit the Safe7579 adapter itself.

**Adapter disabling risk:** If Safe owners call `Safe.disableModule(safe7579Adapter)`, all ERC-7579 modules become inert. The Safe reverts to standard multi-sig mode without timelock or policy enforcement. This is by design (owners have ultimate control) but must be monitored. A malicious owner could disable the adapter to bypass timelock for their own operations.

**Fallback handler risk:** The Safe7579 adapter typically registers as the Safe's fallback handler to intercept ERC-7579 calls. If another contract is set as the fallback handler (via `Safe.setFallbackHandler`), the ERC-7579 module system breaks silently.

### Module Installation Security

Module installation goes through `Safe7579.installModule()`, which the Safe calls via `execTransactionFromModule`. Key risks:

1. **Executor privilege escalation:** If SmartSession (an executor module) can trigger `installModule`/`uninstallModule` calls via `executeFromExecutor`, an operator with a session key could install arbitrary modules. SmartSession's policy configuration MUST explicitly block these selectors.

2. **Circular dependency:** Installing a new hook that depends on the timelock hook already being installed requires careful ordering. The factory should handle this (but currently has encoding issues per H-05).

3. **Threshold bypass:** Module installation requires a full Safe transaction (owner threshold). There is no way for a single owner in a 2-of-3 Safe to unilaterally install modules. This is correct.

### Factory Deployment Security

**CREATE2 determinism:** The factory uses `safeProxyFactory.createProxyWithNonce` with a salt derived from `keccak256(setupCalldata) + saltNonce`. The predicted address is correct per the CREATE2 formula.

**Front-running analysis:**
1. Attacker observes pending UserOperation with initCode targeting the factory.
2. Attacker calls `createProxyWithNonce` with the same parameters directly on the Safe proxy factory.
3. The Safe is deployed at the predicted address with the correct configuration (same owners, same modules).
4. The legitimate UserOperation fails because the address is already occupied.
5. **Attacker gains nothing** -- the deployed Safe has the legitimate owners, not the attacker's.
6. However, the legitimate user must use a different salt to deploy at a different address, which may break pre-funded addresses.

**Recommendation:** Fund the predicted address only after deployment is confirmed, or use a deployment pattern that includes a nonce only the deployer knows.

**Launchpad re-initialization risk:** The Safe7579 Launchpad pattern typically includes a one-time initialization guard (e.g., the Safe's `setup` function can only be called once because it checks that `threshold == 0` indicating uninitialized). This is not auditable in this prototype since the Launchpad is mocked.

---

## Test Coverage Assessment

### Coverage Matrix

| Contract | Unit Tests | Integration Tests | Edge Cases | Negative Tests | Fuzz Tests |
|----------|-----------|-------------------|------------|----------------|------------|
| ManagedAccountTimelockHook | 13 | 6 | Partial | Good | None |
| HookMultiPlexer | **0** (standalone) | 2 (via integration) | **None** | **None** | None |
| UniswapSwapPolicy | 8 | 2 | Partial | Good | None |
| AaveSupplyPolicy | 7 | 1 | Partial | Good | None |
| ApprovalPolicy | 6 | 2 | Partial | Good | None |
| ManagedAccountSafeFactory | 8 | 1 | Partial | Good | None |

### Critical Test Gaps

1. **HookMultiPlexer has no standalone test file.** There are no tests for:
   - `addHook()` and `removeHook()` correctness
   - Adding more than `MAX_HOOKS` hooks (should revert)
   - Adding duplicate hooks (should revert)
   - Removing a hook from the middle and verifying order change
   - `onUninstall()` clearing all hooks
   - `preCheck`/`postCheck` with multiple hooks
   - `postCheck` with mismatched hookData length
   - Reentrancy during sub-hook iteration

2. **No replay/re-queue tests.** No test verifies that a consumed operation can be re-queued, or that a re-queued operation with the same hash works correctly.

3. **No cross-account isolation tests.** No tests verify that Account A's configurations/volumes/queues do not affect Account B.

4. **No fuzz tests.** The test suite uses only hardcoded values. Foundry's built-in fuzzer should be used for:
   - `_extractTargetAndSelector` with random calldata
   - Volume tracking arithmetic with edge values
   - Timestamp edge cases around cooldown/expiration boundaries
   - Random ABI encodings in policy `checkAction`

5. **No batch execution mode tests.** All tests use `mode = bytes32(0)` (single execution).

6. **Factory `predictAddress` is not verified against actual deployment.** Tests check determinism (same params -> same address) but never deploy a proxy and compare the actual address to the prediction.

7. **No test for `onInstall` with `address(0)` safeAccount.** Tests always pass a valid MockSafe. No test simulates the factory's broken flow (H-02).

8. **Integration tests do not route through HookMultiPlexer.** The integration tests call `timelockHook.preCheck()` directly rather than going through `hookMultiplexer.preCheck()`, which means the multiplexer's aggregation logic is never tested in context.

---

## Recommendations

### Priority 1: Must Fix (Critical/High -- blocks any deployment)

| # | Finding | Action |
|---|---------|--------|
| 1 | C-01: Open `queueOperation()` | Add `msg.sender` check: only account or operator can queue |
| 2 | C-02: No owner check in `cancelExecution()` | Pass `msgSender` parameter and verify against Safe owners |
| 3 | H-01: Unprotected policy `checkAction()` | Add `msg.sender` validation to prevent volume griefing |
| 4 | H-02: Factory passes `address(0)` safeAccount | Use `msg.sender` as safeAccount in `onInstall`, or predict address |
| 5 | H-04: Reentrancy in HookMultiPlexer | Cache hooks array in memory before iteration |
| 6 | H-05: Encoding mismatch factory/multiplexer | Fix factory encoding to match `address[]` format |
| 7 | H-06: No batch mode handling | Check execution mode and revert on unsupported modes |

### Priority 2: Should Fix (Medium)

| # | Finding | Action |
|---|---------|--------|
| 8 | H-03: `abi.encodePacked` hash collision | Replace with `abi.encode` |
| 9 | M-01: Silent defaults for malformed calldata | Revert instead of returning `(address(0), bytes4(0))` |
| 10 | M-02: No minimum cooldown enforcement | Enforce `MIN_COOLDOWN >= 5 minutes` |
| 11 | M-03: Day boundary volume exploit | Consider rolling 24-hour window |
| 12 | M-04: Hook order change on removal | Use array shift or document limitation |
| 13 | M-05: No safeAccount validation in `onInstall` | Validate or derive from `msg.sender` |
| 14 | M-06: Stale state after `onUninstall` | Add nonce or cleanup logic |
| 15 | M-07: No length check in `postCheck` | Add `require(allHookData.length == len)` |

### Priority 3: Recommended (Low/Informational)

| # | Finding | Action |
|---|---------|--------|
| 16 | L-01: No timelock param validation in factory | Add checks |
| 17 | L-02: Unused `immediateSelectors` in factory | Wire or remove |
| 18 | L-03: Missing lifecycle events | Add install/uninstall events |
| 19 | L-04: No policy init guard | Document as by-design |
| 20 | L-05: `view` inconsistency in ApprovalPolicy | Align interface |
| 21 | L-06: No duplicate owner check | Add or document Safe handles it |
| 22 | Add comprehensive HookMultiPlexer standalone tests | |
| 23 | Add fuzz tests for all calldata parsing | |
| 24 | Add batch execution mode support or explicit rejection | |
| 25 | Add integration tests that route through HookMultiPlexer | |
| 26 | Import canonical interfaces for production | |

---

## Comparison with Arch A Review

Since the `ManagedAccountTimelockHook` and the three policy contracts (`UniswapSwapPolicy`, `AaveSupplyPolicy`, `ApprovalPolicy`) are stated to be identical across architectures, the findings from the Arch A review (C-01, C-02, H-01, H-03, M-01, M-02, M-03) apply equally here.

The Arch B-specific findings are:
- **H-02 (address(0) safeAccount)** -- Factory-specific to Arch B
- **H-04 (HookMultiPlexer reentrancy)** -- Unique to Arch B
- **H-05 (encoding mismatch)** -- Factory/multiplexer specific to Arch B
- **H-06 (batch mode bypass)** -- Applies to both but more critical in Arch B due to Safe7579 adapter's support for multiple execution modes
- **M-04, M-06, M-07** -- HookMultiPlexer-specific to Arch B
- **Safe-specific analysis section** -- Entirely unique to Arch B

---

## Flash Loan Attack Analysis

**Can flash loans bypass the timelock?** No -- the timelock requires an operation to be queued in a prior transaction (different block). Flash loan attacks occur within a single transaction. An attacker cannot:
1. Flash loan funds
2. Queue an operation (succeeds)
3. Wait for cooldown (impossible within one transaction)
4. Execute the operation

The timelock's multi-block nature inherently defeats flash loan attacks.

**Can flash loans bypass policies?** The daily volume tracking operates on `block.timestamp / 1 days`. A flash loan could call `checkAction` multiple times within one block, but each call increments `vol.consumed`, so the daily limit still applies. The attacker would exhaust the daily limit (a griefing vector per H-01) but cannot bypass the limit itself.

---

## Proxy/Storage Collision Analysis

The contracts use standard Solidity storage layout with mappings keyed by `msg.sender` (the account address). There are no custom storage slots, no `delegatecall` to external implementations, and no assembly-level storage manipulation.

The Safe proxy itself uses EIP-1967 storage slots for its implementation address, which do not conflict with module storage since modules are separate contracts with their own storage.

The Safe7579 adapter may use storage within the Safe's context (if it's set as a module that can delegatecall). This is outside the scope of this review but is a known consideration in the Safe7579 architecture.

**Verdict:** No storage collision risk in the custom contracts.

---

## Disclaimer

This review covers only the custom smart contracts in `prototypes/arch-b-safe7579/src/`. The following components are **out of scope** and require separate security audits:

- Safe singleton and proxy contracts
- Safe7579 adapter contract
- Safe7579 Launchpad contract
- SafeProxyFactory contract
- SmartSession module
- OwnableValidator module
- ERC-4337 EntryPoint
- Bundler and paymaster infrastructure
- Off-chain relayer/operator infrastructure

This is a manual code review based on static analysis. No dynamic analysis, formal verification, fuzzing, or live deployment testing was performed. Findings are based on the code as reviewed; subsequent changes may introduce new vulnerabilities or resolve existing ones.
