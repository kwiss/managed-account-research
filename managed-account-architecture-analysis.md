# ManagedAccount — EVM Architecture Study

**Context**: Implementing the ManagedAccount system using modern Account Abstraction infrastructure
**Reference**: Glider.fi as architectural model

---

## Executive Summary

The ManagedAccount document describes a "delegated execution with preserved custody" system using Safe + Zodiac Modules. After analyzing existing solutions, **3 viable architectures** emerge with different tradeoffs.

| Architecture | Complexity | Flexibility | Time-to-Market |
|-------------|-----------|-------------|----------------|
| A. Safe + Zodiac (as-is) | Medium | Limited | ✅ Fast |
| B. Safe + ERC-7579 | High | ✅ Maximum | Medium |
| C. Kernel (ZeroDev) | Medium | High | Medium |

**Recommendation**: Architecture B (Safe + ERC-7579) for the best balance of features/adoption/security.

---

## 1. Analysis of the Existing Landscape: Glider.fi

Glider is the closest benchmark to the ManagedAccount use case. Here is their stack:

### 1.1 Glider Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                       USER (EOA)                             │
│   Signs "scoped session keys" (granular permissions)         │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    SMART VAULTS                              │
│   • Deployed lazily on each chain                           │
│   • Non-custodial (user = owner)                            │
│   • Isolated per user                                       │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│               GLIDER ORCHESTRATION LAYER                     │
│   1. Evaluates the strategy off-chain                       │
│   2. Computes the "Rebalance Diff"                          │
│   3. Generates an intent                                     │
│   4. Solver finds the optimal route                         │
│   5. Executes the calldata via session key                  │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    DEFI PROTOCOLS                            │
│   AMMs, DEXs, CEXs, OTC, Lending, Vaults...                 │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 Glider Repos (GitHub)

| Repo | Fork of | Usage |
|------|---------|-------|
| `alto` | pimlicolabs/alto | Custom ERC-4337 bundler |
| `ultra-relay` | zerodevapp/ultra-relay | Optimized relay |
| `verifying-paymaster` | coinbase/verifying-paymaster | Gas sponsoring |
| `erpc-railway-deployment` | erpc/railway | RPC infrastructure |

**Insight**: Glider forked the Pimlico bundler rather than using their API → they want to control the infrastructure.

### 1.3 Key Differences: Glider vs ManagedAccount

| Aspect | Glider | ManagedAccount |
|--------|--------|----------------|
| Focus | Automatic portfolio rebalancing | Generic execution delegation |
| Permission model | Session keys + intent-based | Roles + explicit whitelist |
| Security | Scoped, revocable permissions | Delay module + owner cancel |
| Multi-chain | Native (chain abstraction) | Not specified |
| Use case | Retail investors | Institutional / DAO / Social trading |

---

## 2. Relevant EVM Standards

### 2.1 ERC-4337 (Account Abstraction)

The foundational standard. Enables:
- **UserOperations**: meta-transactions signed by smart accounts
- **Bundlers**: aggregate UserOps and submit them on-chain
- **Paymasters**: sponsor gas (gasless UX)
- **EntryPoint**: singleton contract that orchestrates everything

```
UserOp = {
    sender,           // Smart account address
    nonce,            // Replay protection
    initCode,         // Deployment bytecode (if new)
    callData,         // The action to execute
    callGasLimit,     // Gas for execution
    verificationGasLimit,
    preVerificationGas,
    maxFeePerGas,
    maxPriorityFeePerGas,
    paymasterAndData, // Paymaster address + data
    signature         // Validation signature(s)
}
```

### 2.2 ERC-7579 (Modular Smart Accounts)

Interoperability standard for modules. Defines 4 module types:

| Type | Function | Example |
|------|----------|---------|
| **Validator** | Verifies signatures | ECDSA, Passkeys, Multisig |
| **Executor** | Executes actions | Scheduled txs, Automation |
| **Fallback** | Handles unknown calls | ERC-721 receiver |
| **Hook** | Pre/post execution logic | Rate limiting, Audit |

**Major advantage**: An ERC-7579 module works on Safe, Kernel, Biconomy, etc.

### 2.3 ERC-7710 / ERC-7715 (Delegation Framework)

Emerging standards (MetaMask Delegation Toolkit):
- **ERC-7710**: How an account delegates permissions to another
- **ERC-7715**: How a dApp requests permissions (`wallet_grantPermissions`)

### 2.4 EIP-7702 (Set EOA Account Code)

Allows EOAs to temporarily behave like smart accounts. Planned for the Pectra upgrade.

**Impact**: Users will be able to keep their existing EOA and benefit from AA features.

---

## 3. Possible Architectures

### Architecture A: Safe + Zodiac (Original Document)

This is the architecture described in the ManagedAccount specification.

```
┌──────────────────────────────────────────────────────┐
│                      OWNER (EOA)                      │
└──────────────────────────────────────────────────────┘
                          │
          ┌───────────────┴───────────────┐
          ▼                               ▼
┌──────────────────┐            ┌──────────────────────┐
│   Direct access  │            │     Via Modules      │
│   (full control) │            │                      │
└──────────────────┘            └──────────────────────┘
                                          │
                    ┌─────────────────────┼─────────────────────┐
                    ▼                     ▼                     ▼
           ┌──────────────┐     ┌──────────────┐     ┌──────────────┐
           │ Roles Module │     │ Delay Module │     │ 4337 Module  │
           │   (Zodiac)   │ ──▶ │   (Zodiac)   │     │  (Safe AA)   │
           └──────────────┘     └──────────────┘     └──────────────┘
                    │                     │
                    ▼                     ▼
           ┌──────────────────────────────────────┐
           │              SAFE PROXY              │
           │          (holds all funds)           │
           └──────────────────────────────────────┘
                              │
                              ▼
           ┌──────────────────────────────────────┐
           │           DeFi Protocols             │
           └──────────────────────────────────────┘
```

**Components**:
- **Safe Singleton**: The reference implementation
- **SafeProxyFactory**: Deploys proxies (CREATE2)
- **Zodiac Roles**: Permission management (target, selector, conditions)
- **Zodiac Delay**: Timelock for operator operations
- **Safe4337Module**: ERC-4337 compatibility

**Advantages**:
- ✅ Battle-tested ($100B+ secured by Safe)
- ✅ Zodiac is mature and audited
- ✅ Architecture well documented in the specification

**Disadvantages**:
- ❌ No native session keys
- ❌ Zodiac modules not interoperable with other smart accounts
- ❌ Delay module = UX friction (systematic cooldown)
- ❌ No native chain abstraction

---

### Architecture B: Safe + ERC-7579 (Recommended)

Uses the **Safe7579 Adapter** (developed by Safe + Rhinestone) to make Safe ERC-7579 compatible.

```
┌──────────────────────────────────────────────────────┐
│                      OWNER (EOA)                      │
└──────────────────────────────────────────────────────┘
                          │
                          ▼
┌──────────────────────────────────────────────────────┐
│                 SAFE + 7579 ADAPTER                   │
│  ┌────────────────────────────────────────────────┐  │
│  │              Safe7579 Module                    │  │
│  │  (Adapter = Safe Module + Fallback Handler)    │  │
│  └────────────────────────────────────────────────┘  │
│                          │                           │
│     ┌────────────────────┼────────────────────┐     │
│     ▼                    ▼                    ▼     │
│ ┌──────────┐      ┌──────────┐      ┌──────────┐   │
│ │Validator │      │ Executor │      │  Hook    │   │
│ │ Modules  │      │ Modules  │      │ Modules  │   │
│ └──────────┘      └──────────┘      └──────────┘   │
│                                                     │
│   Examples:                                         │
│   • Session Key Validator                          │
│   • Ownable Executor (Rhinestone)                  │
│   • Scheduled Orders                               │
│   • Social Recovery                                │
│   • Dead Man Switch                                │
└──────────────────────────────────────────────────────┘
                          │
                          ▼
┌──────────────────────────────────────────────────────┐
│              PIMLICO INFRASTRUCTURE                   │
│  ┌────────────┐  ┌────────────┐  ┌────────────┐     │
│  │   Alto     │  │ Verifying  │  │ ERC-20     │     │
│  │  Bundler   │  │ Paymaster  │  │ Paymaster  │     │
│  └────────────┘  └────────────┘  └────────────┘     │
└──────────────────────────────────────────────────────┘
```

**Components**:
- **Safe Proxy**: Same base as Architecture A
- **Safe7579 Adapter**: Bridge Safe ↔ ERC-7579
- **Rhinestone Modules**: 14 audited modules available
- **Module Registry**: On-chain security verification
- **Pimlico Stack**: Bundler + Paymasters

**ManagedAccount → ERC-7579 Mapping**:

| ManagedAccount Concept | ERC-7579 Equivalent |
|------------------------|---------------------|
| Roles Module | Validator Module (custom) |
| Delay Module | Hook Module (pre-execution) |
| Operator permissions | Session Key Validator |
| execute() / multicall() | Executor Module |

**Advantages**:
- ✅ Interoperability (reusable modules)
- ✅ Rich ecosystem (Safe, Rhinestone, Pimlico collaboration)
- ✅ Native session keys
- ✅ Module Registry = verifiable security
- ✅ Future-proof (adopted standard)

**Disadvantages**:
- ⚠️ More complex to set up
- ⚠️ Less control than custom Zodiac
- ⚠️ Dependency on the Rhinestone ecosystem

**Tooling**:
- `permissionless.js`: TypeScript SDK (Pimlico)
- `ModuleSDK`: Module interaction (Rhinestone)
- `ModuleKit`: Custom module creation

---

### Architecture C: Kernel (ZeroDev)

An alternative to Safe — minimal and modular smart account.

```
┌──────────────────────────────────────────────────────┐
│                      OWNER (EOA)                      │
└──────────────────────────────────────────────────────┘
                          │
                          ▼
┌──────────────────────────────────────────────────────┐
│                    KERNEL ACCOUNT                     │
│  ┌────────────────────────────────────────────────┐  │
│  │         Kernel Smart Account (ERC-7579)        │  │
│  │                                                 │  │
│  │  Modes:                                         │  │
│  │  • Sudo Mode (owner full access)               │  │
│  │  • Plugin Mode (delegated via selector)        │  │
│  │  • Enable Mode (install new plugins)           │  │
│  │                                                 │  │
│  └────────────────────────────────────────────────┘  │
│                          │                           │
│     ┌────────────────────┼────────────────────┐     │
│     ▼                    ▼                    ▼     │
│ ┌──────────┐      ┌──────────┐      ┌──────────┐   │
│ │Validator │      │ Executor │      │  Policy  │   │
│ │ Plugins  │      │ Plugins  │      │ Plugins  │   │
│ └──────────┘      └──────────┘      └──────────┘   │
│                                                     │
│   Built-in Features:                                │
│   • Session Keys (granular permissions)            │
│   • Passkey authentication                         │
│   • Social recovery                                │
│   • Gas sponsorship                                │
│   • Chain abstraction                              │
└──────────────────────────────────────────────────────┘
                          │
                          ▼
┌──────────────────────────────────────────────────────┐
│              ZERODEV INFRASTRUCTURE                   │
│  ┌────────────┐  ┌────────────┐  ┌────────────┐     │
│  │  Ultra     │  │  Paymaster │  │  Meta      │     │
│  │  Relay     │  │   API      │  │ Bundler    │     │
│  └────────────┘  └────────────┘  └────────────┘     │
└──────────────────────────────────────────────────────┘
```

**Kernel Concepts**:
- **Sudo Mode**: Owner signature → direct execution
- **Plugin Mode**: Delegates validation to a plugin based on selector
- **Enable Mode**: Activates a new plugin (associates selector → validator + executor)

**Advantages**:
- ✅ Gas-efficient (more minimal than Safe)
- ✅ Best-in-class session keys
- ✅ Native chain abstraction (ZeroDev feature)
- ✅ ERC-7579 compliant
- ✅ Mature SDK (@zerodev/sdk)

**Disadvantages**:
- ❌ Less Lindy than Safe
- ❌ Potential vendor lock-in (ZeroDev infra)
- ❌ Less audit coverage than Safe

---

## 4. Detailed Comparison

### 4.1 Feature Matrix

| Feature | A: Safe+Zodiac | B: Safe+7579 | C: Kernel |
|---------|----------------|--------------|-----------|
| **Custody preservation** | ✅ Native | ✅ Native | ✅ Native |
| **Granular permissions** | ✅ Roles Module | ✅ Validators | ✅ Session Keys |
| **Time-lock safety** | ✅ Delay Module | ⚠️ Via Hook | ⚠️ Via Plugin |
| **Session keys** | ❌ Not native | ✅ Via module | ✅ Native |
| **Gasless (paymaster)** | ✅ 4337 Module | ✅ Pimlico | ✅ ZeroDev |
| **Multi-chain** | ❌ Manual | ⚠️ Limited | ✅ Native |
| **Module interop** | ❌ Zodiac only | ✅ ERC-7579 | ✅ ERC-7579 |
| **Audit status** | ✅ Mature | ✅ Audited | ✅ Audited |

### 4.2 Infrastructure Choices

| Component | Option 1 | Option 2 | Option 3 |
|-----------|----------|----------|----------|
| **Bundler** | Pimlico Alto | Self-hosted Alto | Alchemy Rundler |
| **Paymaster** | Pimlico Verifying | Coinbase Paymaster | Custom |
| **RPC** | eRPC (multiplexer) | Alchemy | Infura |
| **Indexer** | The Graph | Custom | Covalent |

**Infra Recommendation**:
- **Dev/Test**: Pimlico (simple API, free tier)
- **Production**: Self-hosted Alto + Pimlico fallback (like Glider)

### 4.3 Permissions Model Comparison

**ManagedAccount (Zodiac Roles)**:
```solidity
struct Scope {
    address target;
    bytes4 selector;
    Condition[] conditions;
}

enum ConditionType { EqualTo, OneOf, GreaterThan, LessThan }
```

**ERC-7579 Session Key**:
```solidity
struct SessionKeyPermission {
    address target;
    bytes4 selector;
    uint256 valueLimit;
    bytes rules; // Custom encoded rules
    uint48 validAfter;
    uint48 validUntil;
}
```

**ZeroDev Session Key**:
```typescript
const sessionKey = await createSessionKey({
    permissions: [{
        target: UNISWAP_ROUTER,
        functionSelector: "swap(address,uint256,address)",
        valueLimit: parseEther("1"),
        rules: [
            { param: 2, condition: "equal", value: safeAddress }
        ]
    }],
    validUntil: Date.now() + 3600 * 1000
})
```

---

## 5. Recommendation: Architecture B (Safe + ERC-7579)

### 5.1 Why?

1. **Best of both worlds**: Safe security + modular flexibility
2. **Interoperability**: Reusable modules across ecosystems
3. **Future-proof**: ERC-7579 is the emerging standard
4. **Ecosystem support**: Safe + Rhinestone + Pimlico = active collaboration
5. **Time-to-market**: 14 Rhinestone modules ready to use

### 5.2 Implementation Mapping

| ManagedAccount Spec | Implementation |
|---------------------|----------------|
| ManagedAccountFactory | Safe7579Factory (custom) |
| OperatorExecutor | OwnableExecutor (Rhinestone) + custom |
| Roles Module | Session Key Validator + Permission Hook |
| Delay Module | Timelock Hook (custom) |
| 4337 Module | Safe4337Module (included) |

### 5.3 Recommended Tech Stack

```
Frontend
├── viem (base)
├── permissionless.js (AA interactions)
├── @rhinestone/module-sdk (modules)
└── wagmi (React hooks)

Backend (if needed)
├── Node.js / Bun
├── Alto bundler (self-hosted or Pimlico)
└── PostgreSQL (indexing)

Smart Contracts
├── Safe Contracts
├── Safe7579 Adapter
├── Rhinestone Modules
└── Custom modules (if needed)

Infrastructure
├── Pimlico (bundler + paymaster API)
├── eRPC (RPC multiplexing)
└── Railway / Render (hosting)
```

### 5.4 Development Phases

**Phase 1: Core (MVP)**
- [ ] Factory deploying Safe + 7579 Adapter
- [ ] Session Key Validator for operators
- [ ] Basic permission scoping (target + selector)
- [ ] Pimlico integration (gasless)

**Phase 2: Security**
- [ ] Timelock Hook (Delay Module equivalent)
- [ ] Owner cancel mechanism
- [ ] Parameter conditions (EqualTo, OneOf)
- [ ] Emergency procedures

**Phase 3: Advanced**
- [ ] Multi-chain deployment
- [ ] Custom modules
- [ ] Policy engine (rate limiting, oracles)
- [ ] Compliance modules

---

## 6. Questions for Discussion

### Architecture
1. **Multi-chain from the start?** If yes → Kernel may be more suitable
2. **Level of module customization?** If high → plan for custom module development
3. **Who hosts the infra?** Self-hosted or managed?

### Business
4. **Priority use case?** (Institutional, DAO, Social trading)
5. **Compliance requirements?** (Audit trail, jurisdiction restrictions)
6. **Expected volume?** (Impacts infra choice)

### Technical
7. **Target chains?** (Mainnet, Arbitrum, Base, Polygon...)
8. **Preferred testing framework?** (Foundry recommended)
9. **Default cooldown/expiration?**

---

## 7. Resources

### Documentation
- [Safe ERC-7579 Docs](https://docs.safe.global/advanced/erc-7579/overview)
- [Pimlico Docs](https://docs.pimlico.io/)
- [ZeroDev Docs](https://docs.zerodev.app/)
- [Rhinestone ModuleKit](https://docs.rhinestone.wtf/modulekit)
- [ERC-7579 Spec](https://erc7579.com/)

### Repos
- [Safe7579 Adapter](https://github.com/safe-global/safe-modules)
- [Rhinestone Modules](https://github.com/rhinestonewtf/core-modules)
- [Pimlico Alto](https://github.com/pimlicolabs/alto)
- [ZeroDev Kernel](https://github.com/zerodevapp/kernel)
- [permissionless.js](https://github.com/pimlicolabs/permissionless.js)

### Articles
- [Glider Architecture Analysis](https://medium.com/@esedov.cemsid/glider-fi-an-architectural-analysis)
- [Anagram Blog - Glider Introduction](https://blog.anagram.xyz/glider/)
- [Safe + Rhinestone + Pimlico Partnership](https://safe.global/blog/launching-erc-7579-adapter-for-safe)

---

*Document prepared for review — February 2026*
