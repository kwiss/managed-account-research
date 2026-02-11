# Session Keys & Permission Delegation: Cross-Cutting Comparison

## Overview

This document compares five implementations of session keys / permission delegation:

1. **Zodiac Roles v2** -- Gnosis Guild (Safe-native)
2. **Rhinestone SmartSessions** -- ERC-7579 (account-agnostic)
3. **ZeroDev Session Keys** -- Kernel v3 native (ERC-7579 extended)
4. **MetaMask Delegation Toolkit** -- ERC-7710/7715 (delegation framework)
5. **Biconomy Smart Sessions** -- Uses Rhinestone SmartSessions under the hood

---

## 1. Zodiac Roles v2

### Architecture

Zodiac Roles v2 is a **Safe Module** that acts as a permission layer between module callers and the Safe. It is NOT an ERC-4337 component -- it operates in the Safe's native module system.

```
Operator -> Roles Modifier -> [authorize] -> Safe.execTransactionFromModule()
```

### Permission Structure

```solidity
struct Role {
    mapping(address => bool) members;           // Who has this role
    mapping(address => TargetAddress) targets;  // Target-level clearance
    mapping(bytes32 => bytes32) scopeConfig;    // Function-level conditions
}

struct TargetAddress {
    Clearance clearance;       // None, Target (any function), Function (specific)
    ExecutionOptions options;  // None, Send, DelegateCall, Both
}
```

**Hierarchy**: Role -> Target Address -> Function Selector -> Parameter Conditions

### Condition Types (Operators)

Zodiac Roles v2 has the most expressive condition system of all implementations:

| Operator | Type | Description |
|----------|------|-------------|
| `Pass` | Default | Always passes |
| `And` | Logical | All children must pass |
| `Or` | Logical | At least one child passes |
| `Nor` | Logical | No child passes |
| `Matches` | Complex | Calldata/AbiEncoded/Tuple/Array structural match |
| `ArraySome` | Complex | At least one array element matches |
| `ArrayEvery` | Complex | All array elements match |
| `ArraySubset` | Complex | Matched elements form a subset |
| `EqualToAvatar` | Special | Parameter must equal the Safe address |
| `EqualTo` | Comparison | Exact match (static/dynamic/tuple/array) |
| `GreaterThan` | Comparison | Unsigned greater than |
| `LessThan` | Comparison | Unsigned less than |
| `SignedIntGreaterThan` | Comparison | Signed integer greater than |
| `SignedIntLessThan` | Comparison | Signed integer less than |
| `Bitmask` | Comparison | Bitwise mask comparison |
| `Custom` | Comparison | Delegate to external contract |
| `WithinAllowance` | Spending | Check against allowance tracker |
| `EtherWithinAllowance` | Spending | ETH value within allowance |
| `CallWithinAllowance` | Spending | Call count within allowance |

**Source**: `repos/zodiac-modifier-roles/packages/evm/contracts/Types.sol:48-105`

### Allowance System

```solidity
struct Allowance {
    uint128 refill;       // Amount added per period
    uint128 maxRefill;    // Cap on balance after refill
    uint64 period;        // Seconds between refills (0 = one-time)
    uint128 balance;      // Current remaining balance
    uint64 timestamp;     // Last refill timestamp
}
```

This enables spending limits that **automatically replenish** -- e.g., "operator can spend 1000 USDC per day".

### Time Bounds

No native time bounds on roles. Roles are persistent until revoked by the owner. Time-based restrictions must be implemented via the Zodiac Delay module or external conditions.

### Revocation

- Owner calls `assignRoles(module, [roleKey], [false])` to revoke
- Immediate effect, no delay
- Can also disable the entire module via `disableModule()`

### "Recipient Must Be Account" Rule

**`EqualToAvatar` operator**: Directly enforces that a parameter must equal the Safe (avatar) address. This is purpose-built for "funds must return to this account" rules.

### "Only Approved DeFi Protocols" Rule

**Target-level clearance**: Each role has per-address clearance settings. Set `Clearance.Function` for approved protocol addresses and scope specific function selectors.

### Gas Overhead

- Permission check: ~20-50K gas per transaction (depends on condition tree depth)
- Allowance tracking: Additional ~5-10K for stateful checks
- No UserOp overhead (not 4337-based)

### Summary

| Feature | Zodiac Roles v2 |
|---------|----------------|
| Account type | Safe only |
| Standard | Zodiac (Safe module) |
| Condition operators | 18+ (most expressive) |
| Nested conditions | Yes (And/Or/Nor trees) |
| Array conditions | Yes (Some/Every/Subset) |
| Time bounds | No native (use Delay module) |
| Value limits | Yes (WithinAllowance + refill) |
| Call count limits | Yes (CallWithinAllowance) |
| Revocation | Immediate (owner tx) |
| EqualToAvatar | Yes (built-in) |
| Gas overhead | ~20-50K |

---

## 2. Rhinestone SmartSessions (ERC-7579)

### Architecture

SmartSessions is an **ERC-7579 Validator module** that acts as a session key manager. It is installed on any ERC-7579 compatible account (Safe via Safe7579, Kernel, Nexus, etc.).

```
Session Key Holder -> UserOp -> EntryPoint -> Account.validateUserOp()
                                                -> SmartSessions.validateUserOp()
                                                    -> Check policies
                                                    -> Check session validator signature
```

### Permission Structure

```solidity
struct Session {
    ISessionValidator sessionValidator;    // Signature validator contract
    bytes sessionValidatorInitData;        // Validator config (e.g., session public key)
    bytes32 salt;                          // Uniqueness salt
    PolicyData[] userOpPolicies;           // Policies checked on every UserOp
    ERC7739Data erc7739Policies;           // ERC-1271 signature policies
    ActionData[] actions;                  // Per-action policies
}

struct ActionData {
    bytes4 actionTargetSelector;           // Function selector
    address actionTarget;                  // Target contract
    PolicyData[] actionPolicies;           // Policies for this specific action
}

struct PolicyData {
    address policy;                        // Policy contract address
    bytes initData;                        // Policy initialization data
}
```

**Source**: `repos/modulekit/src/integrations/interfaces/ISmartSession.sol:110-117`

### Policy Types

SmartSessions uses external policy contracts. Available policies (from Rhinestone + Biconomy):

| Policy | Description |
|--------|-------------|
| Universal Action Policy | Broad action permissions with parameter rules |
| Sudo Policy | Unrestricted access |
| Spending Limit Policy | ERC-20 token transfer limits |
| Time Range Policy | validAfter / validUntil timestamps |
| Value Limit Policy | Native token (ETH) value cap per transaction |
| Usage Limit Policy | Maximum number of executions |

### Condition Types (via Universal Action Policy)

Six parameter comparison operators:
- `EQUAL`
- `GREATER_THAN`
- `LESS_THAN`
- `GREATER_THAN_OR_EQUAL`
- `LESS_THAN_OR_EQUAL`
- `NOT_EQUAL`

### Time Bounds

- `sessionValidUntil`: Timestamp when session expires
- `sessionValidAfter`: Timestamp when session becomes active
- Enforced at the SmartSessions level

### Value Limits

- Per-transaction native value limit (Value Limit Policy)
- Per-token spending limits (Spending Limit Policy)
- Both are stateful and track cumulative usage

### Call Count Limits

- Usage Limit Policy tracks number of executions
- Not automatically replenishing (unlike Zodiac Roles)

### Revocation

Multiple revocation mechanisms:
- `removeSession(permissionId)`: Removes entire session
- `revokeEnableSignature(permissionId)`: Invalidates enable-mode sessions
- `disableActionPolicies()`: Remove specific action permissions
- `disableUserOpPolicies()`: Remove UserOp-level policies
- `disableActionId()`: Disable specific action target+selector

### Multi-Chain Support

SmartSessions has native multi-chain session creation:
- `ChainDigest[]` allows signing sessions for multiple chains atomically
- Uses chain-agnostic domain separator for cross-chain signatures
- `chainDigestIndex` identifies which chain's digest to verify

**Source**: `repos/modulekit/src/test/helpers/SmartSessionHelpers.sol`

### "Recipient Must Be Account" Rule

Must be implemented via Universal Action Policy with parameter condition: check that recipient parameter `EQUAL` to the account address. No built-in `EqualToAvatar` equivalent.

### "Only Approved DeFi Protocols" Rule

`ActionData[]` array: each entry specifies `(actionTarget, actionTargetSelector, actionPolicies[])`. Only listed actions are allowed. Unlisted contracts/functions are rejected.

### Gas Overhead

- Session validation: ~15-40K per UserOp
- Per-policy check: ~5-10K each
- Signature decompression (FLZ): ~3-5K

### Summary

| Feature | SmartSessions |
|---------|--------------|
| Account type | Any ERC-7579 |
| Standard | ERC-7579 validator module |
| Condition operators | 6 (basic comparison) |
| Nested conditions | No |
| Array conditions | No |
| Time bounds | Yes (validAfter/validUntil) |
| Value limits | Yes (per-tx native + ERC-20) |
| Call count limits | Yes (Usage Limit Policy) |
| Revocation | Multiple options (session/policy/action) |
| EqualToAvatar | No (manual parameter check) |
| Multi-chain | Yes (native ChainDigest) |
| Gas overhead | ~15-40K |

---

## 3. ZeroDev Session Keys (Kernel v3)

### Architecture

Kernel's session keys use the native Permission validation type (type `0x02`). A permission is a combination of one Signer + N Policies.

```
Session Key Holder -> UserOp (nonce encodes PermissionId)
    -> EntryPoint -> Kernel.validateUserOp()
        -> ValidationManager._validateUserOp(PERMISSION, ...)
            -> For each Policy: checkUserOpPolicy()
            -> Signer: checkUserOpSignature()
```

### Permission Structure

```solidity
struct PermissionConfig {
    PassFlag permissionFlag;   // SKIP_USEROP (0x0001) | SKIP_SIGNATURE (0x0002)
    ISigner signer;            // Session key signer
    PolicyData[] policyData;   // Array of (PassFlag, PolicyAddress)
}
```

**Source**: `repos/kernel/src/core/ValidationManager.sol:92-97`

### Policy Types (from kernel-7579-plugins)

| Policy | Description |
|--------|-------------|
| Call Policy | Target + selector + parameter conditions |
| Gas Policy | Gas spending limits |
| Rate Limit Policy | N calls per time period |
| Timestamp Policy | validAfter / validUntil |
| Signature Policy | ERC-1271 signing constraints |
| Sudo Policy | Unrestricted access |
| Custom Policy | Implement IPolicy interface |

### Condition Types (Call Policy)

- Equal to
- Greater than / Less than
- Not equal
- One of (set membership)
- Custom (external contract)

### Time Bounds

- Enforced via `ValidAfter` / `ValidUntil` in `ValidationData`
- Each policy can return time bounds that are intersected (most restrictive wins)
- Timestamp Policy provides explicit time windows
- Also encodable in the signer's response

### Value Limits

- Gas Policy: limits total gas spending
- Call Policy: can enforce value limits through parameter conditions
- Custom policies can track cumulative spending

### Call Count Limits

- Rate Limit Policy: N calls per time window
- Stateful tracking per permission

### Revocation

Two mechanisms:
1. **Nonce invalidation**: `invalidateNonce(nonce)` revokes ALL permissions with nonce < specified value. This is a nuclear option that revokes many permissions at once.
2. **Validation uninstall**: `uninstallValidation(vId, ...)` removes a specific permission.
3. **Selector revocation**: `grantAccess(vId, selector, false)` removes access to specific selectors.

### Enable Mode (Just-in-Time Installation)

Kernel uniquely supports installing a permission **within the first UserOp** that uses it:
- UserOp nonce specifies `ENABLE` mode
- Signature includes validator install data + root validator approval signature
- Permission is installed and then immediately used
- Great for UX: session key creation doesn't require a separate transaction

### "Recipient Must Be Account" Rule

Must be implemented via Call Policy parameter condition: check that recipient argument equals the Kernel account address. No built-in `EqualToAvatar` equivalent.

### "Only Approved DeFi Protocols" Rule

Two layers:
1. `allowedSelectors` mapping: Only allowed function selectors can be called
2. Call Policy: Restrict to specific target addresses

### Gas Overhead

- Permission validation: ~20-50K per UserOp (depends on number of policies)
- Per-policy: ~5-15K
- Signer verification: ~3-8K (ECDSA)
- Nonce parsing: ~2-3K
- Enable mode adds: ~30-50K (one-time installation cost)

### Summary

| Feature | ZeroDev Session Keys |
|---------|---------------------|
| Account type | Kernel only |
| Standard | Kernel-native (ERC-7579 extended) |
| Condition operators | 5+ (equal, gt, lt, ne, oneOf, custom) |
| Nested conditions | No (flat policy array) |
| Array conditions | No |
| Time bounds | Yes (ValidAfter/ValidUntil, Timestamp Policy) |
| Value limits | Yes (Gas Policy, custom) |
| Call count limits | Yes (Rate Limit Policy) |
| Revocation | Nonce invalidation (bulk) + individual uninstall |
| EqualToAvatar | No (parameter condition) |
| Multi-chain | Yes (MultiChainValidator) |
| Enable mode | Yes (install in first UserOp) |
| Gas overhead | ~20-50K |

---

## 4. MetaMask Delegation Toolkit (ERC-7710/7715)

### Architecture

The Delegation Toolkit uses a fundamentally different model: **delegation chains**. Instead of session keys, an account delegates execution rights to another account, with caveats restricting what can be done.

```
Delegate -> DelegationManager.redeemDelegation(delegation, caveats)
    -> Verify delegation signature
    -> For each caveat: enforcer.beforeHook()
    -> Delegator.executeFromExecutor(execution)
    -> For each caveat: enforcer.afterHook()
```

### Permission Structure

Delegation is a signed message from the delegator specifying:
- **Delegate**: Who can redeem (or `address(0)` for open delegation)
- **Caveats**: Array of (enforcer address, terms) pairs
- **Signature**: Delegator's approval

Delegations can be **chained**: Alice delegates to Bob, Bob redelegates to Carol. Each link can add additional caveats (restrictions can only be tightened, never loosened).

### Delegation Types

| Type | Description |
|------|-------------|
| Root Delegation | Delegator grants own authority |
| Open Root Delegation | Any account can redeem |
| Redelegation | Delegate passes permissions to another |
| Open Redelegation | Redelegation without specific delegate |

### Caveat Enforcers (Built-in)

| Enforcer | Description |
|----------|-------------|
| `AllowedTargetsEnforcer` | Whitelist of callable addresses |
| `AllowedMethodsEnforcer` | Whitelist of function selectors |
| `AllowedCalldataEnforcer` | Calldata pattern matching |
| `TimestampEnforcer` | Time window (validAfter/validUntil) |
| `BlockNumberEnforcer` | Block number range |
| `LimitedCallsEnforcer` | Maximum redemption count |
| `ERC20TransferAmountEnforcer` | ERC-20 transfer limits |
| `ERC20BalanceChangeEnforcer` | ERC-20 balance delta limits |
| `NativeTokenTransferAmountEnforcer` | ETH transfer limits |
| `NativeBalanceGteEnforcer` | Minimum native balance requirement |
| `ValueLteEnforcer` | Maximum msg.value |
| `NonceEnforcer` | Nonce-based ordering |
| `IdEnforcer` | Delegation identification |
| `DeployedEnforcer` | Verify code exists at address |
| `RedeemerEnforcer` | Whitelist of redeemers |
| `ArgsEqualityCheckEnforcer` | Argument equality validation |
| `NativeTokenPaymentEnforcer` | Require native token payment |

Custom enforcers can be built by implementing `ICaveatEnforcer`.

### Time Bounds

- `TimestampEnforcer`: validAfter / validUntil
- `BlockNumberEnforcer`: block number range

### Value Limits

- `ValueLteEnforcer`: Maximum msg.value per call
- `NativeTokenTransferAmountEnforcer`: Native token transfer limit
- `ERC20TransferAmountEnforcer`: ERC-20 transfer limit
- `ERC20BalanceChangeEnforcer`: Net balance change limit

### Call Count Limits

- `LimitedCallsEnforcer`: Maximum number of delegation redemptions

### Revocation

- Delegator can revoke by on-chain transaction
- Revocation is checked during `redeemDelegation` validation
- Entire delegation chain is invalidated if any link is revoked

### "Recipient Must Be Account" Rule

- `AllowedCalldataEnforcer`: Can enforce specific parameter values in calldata
- `ArgsEqualityCheckEnforcer`: Verify argument equality
- Less ergonomic than Zodiac's `EqualToAvatar` but achievable

### "Only Approved DeFi Protocols" Rule

- `AllowedTargetsEnforcer`: Whitelist of contract addresses
- `AllowedMethodsEnforcer`: Whitelist of function selectors
- Can be combined via caveat stacking

### Gas Overhead

- Delegation verification: ~20-40K (signature + caveat checks)
- Per-enforcer: ~5-15K (beforeHook + afterHook)
- Delegation chain traversal: ~10K per link
- Overall: ~30-80K for a typical delegation with 3-4 enforcers

### Unique Features

1. **Delegation chains**: Permissions can be passed along and further restricted
2. **Open delegations**: No specific delegate required
3. **ERC-7715 compatibility**: Standard permission request format for dapps
4. **Audited by Consensys Diligence** (August 2024)

### Summary

| Feature | MetaMask Delegation |
|---------|-------------------|
| Account type | MetaMask Smart Account (ERC-7579) |
| Standard | ERC-7710/7715 |
| Condition operators | Per-enforcer (various) |
| Nested conditions | No (flat caveat array, but delegation chains add depth) |
| Array conditions | No |
| Time bounds | Yes (Timestamp + BlockNumber enforcers) |
| Value limits | Yes (ETH + ERC-20 enforcers) |
| Call count limits | Yes (LimitedCallsEnforcer) |
| Revocation | On-chain revocation (cascades through chain) |
| EqualToAvatar | No (ArgsEqualityCheck) |
| Delegation chains | Yes (unique feature) |
| Gas overhead | ~30-80K |

---

## 5. Biconomy Smart Sessions

### Architecture

Biconomy's Nexus account uses the **Rhinestone SmartSessions** module as its session key system. This is a collaborative effort between Biconomy and Rhinestone.

The architecture is essentially identical to Rhinestone SmartSessions (Section 2), but Biconomy provides:
- Higher-level SDK (`@biconomy/sdk`)
- Managed bundler and paymaster infrastructure
- Additional policy wrappers

### Policy Types

Same as SmartSessions plus Biconomy-specific wrappers:

| Policy | Description |
|--------|-------------|
| Universal Action Policy | Per-function parameter rules |
| Sudo Policy | Unrestricted access |
| Spending Limit Policy | ERC-20 token spending caps |
| Time Range Policy | validAfter / validUntil |
| Value Limit Policy | Native token value cap |
| Usage Limit Policy | Max execution count |

### Condition Types

Six parameter comparison operators (same as SmartSessions):
- `EQUAL`, `GREATER_THAN`, `LESS_THAN`
- `GREATER_THAN_OR_EQUAL`, `LESS_THAN_OR_EQUAL`, `NOT_EQUAL`

### Key Differences from Base SmartSessions

1. **SDK integration**: `grantPermission` and `trustAttesters` via `smartSessionCreateActions`
2. **Registry integration**: Can verify module attestations before enabling
3. **k1Validator dependency**: Requires k1Validator as the active module for session creation

### Summary

| Feature | Biconomy Smart Sessions |
|---------|------------------------|
| Account type | Nexus (ERC-7579) |
| Standard | ERC-7579 (SmartSessions) |
| Condition operators | 6 (basic comparison) |
| Time bounds | Yes |
| Value limits | Yes |
| Call count limits | Yes |
| Revocation | Same as SmartSessions |
| Gas overhead | ~15-40K (same as SmartSessions) |

---

## 6. Detailed Comparison Table

| Feature | Zodiac Roles v2 | SmartSessions | ZeroDev (Kernel) | MetaMask Delegation | Biconomy |
|---------|-----------------|---------------|-------------------|--------------------|---------|
| **Account Compatibility** | Safe only | Any ERC-7579 | Kernel only | MetaMask accounts | Nexus (ERC-7579) |
| **Standard** | Zodiac | ERC-7579 | ERC-7579 extended | ERC-7710/7715 | ERC-7579 |
| **ERC-4337 Native** | No | Yes | Yes | Yes | Yes |
| **Permission Granularity** | | | | | |
| - Target whitelist | Yes | Yes (ActionData) | Yes (Call Policy) | Yes (AllowedTargets) | Yes (ActionData) |
| - Selector whitelist | Yes | Yes (ActionData) | Yes (allowedSelectors) | Yes (AllowedMethods) | Yes (ActionData) |
| - Parameter conditions | 18+ operators | 6 operators | 5+ operators | Per-enforcer | 6 operators |
| - Nested logic (AND/OR) | Yes | No | No | No (flat caveats) | No |
| - Array conditions | Yes (Some/Every/Subset) | No | No | No | No |
| **Time Bounds** | No native | Yes | Yes | Yes | Yes |
| **Value Limits** | | | | | |
| - Native (ETH) | Yes (EtherWithinAllowance) | Yes (Value Limit) | Yes (custom policy) | Yes (ValueLte + NativeTransfer) | Yes (Value Limit) |
| - ERC-20 | Yes (WithinAllowance) | Yes (Spending Limit) | Yes (custom policy) | Yes (ERC20TransferAmount) | Yes (Spending Limit) |
| - Auto-replenishing | Yes (period + refill) | No | No | No | No |
| **Call Count Limits** | Yes (CallWithinAllowance) | Yes (Usage Limit) | Yes (Rate Limit) | Yes (LimitedCalls) | Yes (Usage Limit) |
| - Auto-replenishing | Yes (period + refill) | No | Yes (per time window) | No | No |
| **"Recipient = Account" Rule** | Built-in (EqualToAvatar) | Manual (param check) | Manual (param check) | Manual (ArgsEquality) | Manual (param check) |
| **"Approved Protocols" Rule** | Target clearance | ActionData array | allowedSelectors + Call Policy | AllowedTargets + Methods | ActionData array |
| **Revocation** | | | | | |
| - Individual permission | Yes | Yes | Yes | Yes | Yes |
| - Bulk revocation | Disable module | Remove session | invalidateNonce | Revoke root delegation | Remove session |
| - Immediate | Yes | Yes | Yes | Yes | Yes |
| **Multi-Chain** | No | Yes (ChainDigest) | Yes (MultiChainValidator) | No (per-chain) | Yes (ChainDigest) |
| **Delegation Chains** | No | No | No | Yes | No |
| **Enable in First Tx** | No | Yes (ENABLE mode) | Yes (ENABLE mode) | No | Yes (ENABLE mode) |
| **Gas Overhead** | ~20-50K | ~15-40K | ~20-50K | ~30-80K | ~15-40K |
| **Audit Status** | Audited (multiple) | Audited (Rhinestone) | Audited (ChainLight + Kalos) | Audited (Consensys) | Audited (Cyfrin + Spearbit) |

---

## 7. Capability Assessment for ManagedAccount Use Case

### Requirements Recap

1. Owner deposits/withdraws only (custody preservation)
2. Operators execute whitelisted DeFi operations
3. Granular permissions: target + selector + parameter conditions
4. Time-lock with owner cancellation
5. Gasless UX via paymaster

### Per-Implementation Fit Score

| Requirement | Zodiac Roles v2 | SmartSessions | ZeroDev | MetaMask | Biconomy |
|------------|-----------------|---------------|---------|----------|----------|
| Custody preservation | 5/5 | 4/5 | 4/5 | 4/5 | 4/5 |
| Delegated execution | 5/5 | 5/5 | 5/5 | 4/5 | 5/5 |
| Granular permissions | 5/5 | 3/5 | 4/5 | 3/5 | 3/5 |
| Time-lock + cancel | 3/5* | 2/5 | 3/5** | 2/5 | 2/5 |
| Gasless UX | 2/5*** | 5/5 | 5/5 | 5/5 | 5/5 |
| **Total** | **20/25** | **19/25** | **21/25** | **18/25** | **19/25** |

Notes:
- (*) Zodiac Roles itself has no timelock, but pairs naturally with Zodiac Delay module
- (**) WeightedECDSAValidator provides delay + veto, but not a generic timelock
- (***) Zodiac Roles is not ERC-4337 native; requires wrapping in a UserOp executor module

### Detailed Rationale

**Zodiac Roles v2** has the most expressive condition system (18+ operators, nested logic, array conditions, auto-replenishing allowances, built-in `EqualToAvatar`), but it's Safe-only and not 4337-native. For our use case, the condition expressiveness is very valuable for DeFi operations (e.g., "swap amount must be within daily allowance" or "all addresses in the batch must be in the approved set").

**SmartSessions** (Rhinestone/Biconomy) provides the best account portability (works on any ERC-7579 account) and has a clean session management API. However, its condition system is limited to 6 basic comparison operators with no nesting. For complex DeFi parameter validation, custom policies would need to be written.

**ZeroDev Session Keys** are deeply integrated into Kernel and offer the best gas efficiency. The enable-in-first-tx feature is excellent for UX. The policy system is extensible (custom IPolicy contracts), but built-in policies are less expressive than Zodiac Roles. Rate-limited policies with auto-replenishing counts are a unique strength.

**MetaMask Delegation Toolkit** has a unique delegation chain model that enables interesting patterns (e.g., owner delegates to manager, manager sub-delegates to operators). However, it's newer, has higher gas overhead, and the caveat enforcer ecosystem is still growing. The ERC-7710/7715 standard may become important for wallet interoperability.

**Biconomy Smart Sessions** is essentially SmartSessions with Biconomy's infrastructure. It adds no unique permission capabilities but provides a polished SDK and managed services.

---

## 8. Recommendation: Most Capable Implementation

### For ManagedAccount Specifically

**Recommended: Zodiac Roles v2 (used via Safe7579 + SmartSessions hybrid)**

The ideal architecture combines:

1. **Safe as the account** -- battle-tested, $100B+ TVL
2. **Safe7579 adapter** -- enables ERC-7579 module compatibility
3. **Zodiac Roles v2** -- most expressive permission system for DeFi operations
4. **SmartSessions** -- session key management with 4337 UX
5. **Zodiac Delay** -- time-locked execution with owner cancellation

This hybrid approach gives:
- Zodiac Roles' 18+ condition operators for DeFi parameter validation
- SmartSessions' session key UX and multi-chain support
- ERC-4337 gasless transactions via paymaster
- Safe's security track record

### If Single-Stack Simplicity is Prioritized

**Recommended: ZeroDev / Kernel**

If minimizing integration complexity is the priority:
- Kernel provides the best gas efficiency
- Native permission system (no adapter layers)
- ZeroDev SDK abstracts most complexity
- Enable-in-first-tx for seamless session creation
- Custom IPolicy contracts can match Zodiac Roles' expressiveness (but require development)

### Key Tradeoffs

| Approach | Permission Power | Gas Efficiency | Simplicity | Maturity |
|----------|-----------------|----------------|-----------|----------|
| Safe + Zodiac Roles + SmartSessions | Highest | Lowest | Low (3 systems) | Highest |
| Safe + SmartSessions only | Medium | Medium | Medium | High |
| Kernel + ZeroDev | High (extensible) | Highest | High (single stack) | Medium |
| MetaMask Delegation | Medium | Low | Medium | Low |

---

## 9. Key Code References

| Implementation | Key Source Files |
|---------------|-----------------|
| Zodiac Roles v2 | `repos/zodiac-modifier-roles/packages/evm/contracts/Types.sol` (operators), `Roles.sol` (core) |
| SmartSessions | `repos/modulekit/src/integrations/interfaces/ISmartSession.sol` (interface), `repos/modulekit/src/test/helpers/SmartSessionHelpers.sol` (types + hashing) |
| ZeroDev/Kernel | `repos/kernel/src/core/ValidationManager.sol` (permissions), `repos/kernel/src/interfaces/IERC7579Modules.sol` (IPolicy, ISigner) |
| MetaMask | github.com/MetaMask/delegation-framework (external) |
| Biconomy | github.com/erc7579/smartsessions (same as SmartSessions) |
