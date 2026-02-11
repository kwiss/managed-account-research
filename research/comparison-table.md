# Delegated Smart Account — Master Architecture Comparison

> Compiled from deep-dive research across 15+ analysis files, code reviews of 12 repos, and web research.
> Date: February 2026

---

## 1. Architecture Overview

| # | Architecture | Account Base | Permission System | Key Innovation |
|---|-------------|-------------|-------------------|----------------|
| A | **Safe + Zodiac** | Safe Proxy | Zodiac Roles v2 + Delay | Most expressive on-chain conditions (18+ operators) |
| B | **Safe + ERC-7579** | Safe + Safe7579 Adapter | SmartSession + Hooks | Module interoperability, session keys |
| C | **Kernel (ZeroDev)** | Kernel v3.3 (ERC-1967) | Permission system (Signer + N Policies) | Gas efficiency, enable-in-first-tx |
| D | **Biconomy Nexus** | Nexus (ERC-7579 native) | SmartSessions (shared w/ Rhinestone) | Native 7579, Gemini-validated infra |
| E | **EIP-7702 + ERC-7579** | Owner's EOA (upgraded) | Same ERC-7579 modules | No deployment, no fund migration, -80% activation gas |
| F | **Safe + DeleGator** | Safe | ERC-7710 delegations + caveats | Delegation chains, off-chain creation |
| G | **Kernel + Intent Layer** | Kernel | Intent policies + solver network | Declarative execution (Glider pattern) |
| H | **Safe + Policy Engine** | Safe + Sub-Safes | SafeGuard + TransactionValidator | Operator isolation (Brahma pattern) |

**Not recommended (eliminated):**
- Coinbase Smart Wallet: No granular permissions, no modular architecture
- Light Account (ERC-6900): Vendor lock-in to Alchemy, narrower module ecosystem
- Minimal Custom Account: No battle-testing, full audit cost, no ecosystem
- Soul Wallet / Ambire: Insufficient maturity or feature set

---

## 2. Core Requirements Matrix

| Requirement | A: Safe+Zodiac | B: Safe+7579 | C: Kernel | D: Nexus | E: 7702+7579 | F: Safe+7710 | G: Kernel+Intent | H: Safe+Policy |
|------------|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| **Custody preservation** | 5 | 5 | 5 | 5 | 5 | 5 | 5 | 5 |
| **Delegated execution** | 4 | 5 | 5 | 5 | 5 | 4 | 5 | 4 |
| **Granular permissions** | 5 | 4 | 4 | 4 | 4 | 3 | 3 | 4 |
| **Timelock + cancel** | 5 | 2 | 2 | 2 | 2 | 2 | 2 | 2 |
| **Gasless UX** | 3 | 5 | 5 | 5 | 5 | 4 | 5 | 2 |
| **Multi-chain** | 2 | 3 | 5 | 4 | 4 | 2 | 5 | 3 |
| **TOTAL /30** | **24** | **24** | **26** | **25** | **25** | **20** | **25** | **20** |

**Scoring legend:** 5 = excellent native support, 4 = good (minor gaps), 3 = adequate (workarounds needed), 2 = weak (significant custom work), 1 = not feasible

### Key Observations:
- **No architecture has a native timelock** except Safe+Zodiac (Delay Module). This is custom work everywhere else.
- **ERC-4337 integration** is seamless for B/C/D/E, but requires custom work for A (operator auth)
- **Kernel wins on gas + multi-chain**, Safe wins on **permissions expressiveness + maturity**
- **EIP-7702** is a game-changer for single-owner accounts (no deployment, same modules)

---

## 3. Gas Cost Comparison

| Operation | A: Safe+Zodiac | B: Safe+7579 | C: Kernel | D: Nexus | E: 7702+7579 |
|-----------|:-:|:-:|:-:|:-:|:-:|
| **Account creation** | ~280K | ~400K | ~200K | ~297K | ~25K |
| **Simple transfer (4337)** | ~230K | ~260K | ~180K | ~185K | ~165K |
| **Operator swap (4337)** | ~260K | ~290K | ~210K | ~220K | ~195K |
| **Swap + timelock queue** | ~305K | ~335K | ~260K | ~270K | ~245K |
| **Batch 3 ops (4337)** | N/A* | ~420K | ~350K | ~360K | ~330K |
| **Complex conditions (5+)** | ~290K | ~350K | ~270K | ~280K | ~255K |

*Safe+Zodiac doesn't support native batch for operator operations (requires MultiSend wrapping)*

**Key insight:** Kernel is 25-33% cheaper than Safe per operation. EIP-7702 saves 80% on activation. Over thousands of operator transactions, these differences compound significantly.

---

## 4. Maturity & Security Assessment

| Metric | A: Safe+Zodiac | B: Safe+7579 | C: Kernel | D: Nexus | E: 7702+7579 |
|--------|:-:|:-:|:-:|:-:|:-:|
| **TVL secured** | >$100B (Safe) | >$100B (Safe) | No public figure | No public figure | N/A (EOA-based) |
| **Accounts deployed** | 7M+ (Safe) | 7M+ (Safe) | 3M+ (Kernel) | 4.6M+ (Biconomy) | New (post-Pectra) |
| **Audit count** | 7+ (Safe) + multiple (Zodiac) | Safe + Ackee (Safe7579) | 6 rounds (ChainLight, Kalos) | 4 audits (Spearbit, Cyfrin, Cantina, Zenith) | Protocol-level (Pectra) |
| **Permission system maturity** | HIGH (ENS, GnosisDAO, Balancer use Roles) | MEDIUM (SmartSession is BETA) | MEDIUM-HIGH (3M+ accounts) | MEDIUM (shared SmartSession) | MEDIUM (same 7579 modules) |
| **Production validation for delegation** | HIGH (exact use case) | LOW (newer) | MEDIUM (Glider uses it) | MEDIUM (Gemini integration) | LOW (new paradigm) |
| **Years in production** | 5+ (Safe), 2+ (Roles v2) | 1+ (Safe7579) | 2+ (Kernel v2/v3) | 1+ (Nexus v3) | <1 (Pectra May 2025) |

---

## 5. Permission System Comparison

| Feature | Zodiac Roles v2 | SmartSession | Kernel Policies | ERC-7710 Caveats |
|---------|:-:|:-:|:-:|:-:|
| **Condition operators** | 18+ | 6 | 5+ | Per-enforcer |
| **Nested logic (AND/OR)** | Yes | No | No | No |
| **Array conditions** | Yes (Some/Every/Subset) | No | No | No |
| **"Recipient = account" built-in** | Yes (EqualToAvatar) | No (manual) | No (manual) | No (manual) |
| **Auto-replenishing allowances** | Yes (period + refill) | No | Rate limit only | No |
| **Custom external conditions** | Yes (ICustomCondition) | Yes (policy contracts) | Yes (IPolicy) | Yes (ICaveatEnforcer) |
| **Time bounds** | No native | Yes | Yes | Yes |
| **Value limits** | Yes (ETH + token) | Yes (ETH + token) | Yes (custom) | Yes (ETH + token) |
| **Call count limits** | Yes (with refill) | Yes | Yes (rate limit) | Yes |
| **Multi-chain sessions** | No | Yes (ChainDigest) | Yes (MultiChainValidator) | No |
| **Enable in first tx** | No | Yes | Yes | No |
| **ERC-4337 native** | No | Yes | Yes | Yes |

**Winner for expressiveness:** Zodiac Roles v2 (by far)
**Winner for 4337 integration:** SmartSession / Kernel Policies
**Winner for portability:** SmartSession (any ERC-7579 account)

---

## 6. Vendor Lock-in Assessment

| Architecture | Smart Account | Permission System | Infrastructure | Module Ecosystem | Overall Risk |
|-------------|:-:|:-:|:-:|:-:|:-:|
| A: Safe+Zodiac | LOW (open standard) | MEDIUM (Zodiac-specific) | LOW (self-host Alto) | LOW (Safe ecosystem) | **MEDIUM** |
| B: Safe+7579 | LOW | LOW (ERC-7579 standard) | LOW | LOW (portable modules) | **LOW** |
| C: Kernel | LOW (MIT, ERC-7579) | MEDIUM (Policy/Signer types are Kernel-specific) | MEDIUM (ZeroDev infra) | LOW (ERC-7579 core) | **MEDIUM** |
| D: Nexus | LOW (ERC-7579) | LOW (shared SmartSession) | MEDIUM (Biconomy infra) | LOW | **LOW-MEDIUM** |
| E: 7702+7579 | LOW (protocol-level) | LOW (ERC-7579 standard) | LOW | LOW | **LOW** |
| F: Safe+7710 | LOW | MEDIUM (MetaMask ecosystem) | LOW | MEDIUM | **MEDIUM** |
| G: Kernel+Intent | MEDIUM (Kernel) | HIGH (custom intent layer) | MEDIUM-HIGH | MEDIUM | **MEDIUM-HIGH** |
| H: Safe+Policy | LOW (Safe) | HIGH (Brahma-specific) | HIGH (trusted validator) | LOW | **HIGH** |

---

## 7. Implementation Complexity

| Architecture | Custom Solidity | Custom TypeScript | Estimated LOC | Time to MVP | Requires Audit |
|-------------|:-:|:-:|:-:|:-:|:-:|
| A: Safe+Zodiac | Custom 4337 operator module | Deployment scripts + integration | ~5,000 | 6-8 weeks | Yes (4337 module) |
| B: Safe+7579 | Custom timelock hook + policy contracts | SDK integration | ~5,500 | 8-12 weeks | Yes (hook + policies) |
| C: Kernel | Custom timelock hook + policies | SDK integration | ~4,000 | 6-10 weeks | Yes (hook + policies) |
| D: Nexus | Custom timelock hook | SDK integration | ~4,000 | 6-10 weeks | Yes (hook) |
| E: 7702+7579 | Custom timelock hook | SDK integration | ~3,500 | 5-8 weeks | Yes (hook) |
| F: Safe+7710 | Custom Safe-7710 bridge | Integration code | ~6,000 | 10-14 weeks | Yes (bridge + enforcers) |
| G: Kernel+Intent | Intent policy hook + solver | Full intent infra | ~8,000+ | 12-20 weeks | Yes (extensive) |
| H: Safe+Policy | Guard + validator + policy engine | Backend + off-chain validator | ~7,000+ | 12-16 weeks | Yes (extensive) |

---

## 8. Decision Framework

### If your priority is **SECURITY & INSTITUTIONAL TRUST**:
**A: Safe + Zodiac** or **B: Safe + ERC-7579**
- Safe's $100B+ TVL, 7M+ accounts, 5+ years
- Zodiac Roles v2 proven for exactly this use case (ENS, GnosisDAO, Balancer)

### If your priority is **GAS EFFICIENCY**:
**E: EIP-7702 + ERC-7579** (single-owner) or **C: Kernel** (any)
- 7702 saves 80% on activation
- Kernel is 25-33% cheaper per operation than Safe

### If your priority is **DEVELOPER EXPERIENCE**:
**C: Kernel (ZeroDev)** or **D: Nexus (Biconomy)**
- Best SDKs, most integrated AA infrastructure
- Enable-in-first-tx for seamless session key UX

### If your priority is **FUTURE-PROOFING**:
**E: EIP-7702 + ERC-7579** (primary) + **B: Safe + ERC-7579** (multi-sig)
- Same module ecosystem for both
- Protocol-level foundation (7702) + industry standard (7579)

### If your priority is **PERMISSION EXPRESSIVENESS**:
**A: Safe + Zodiac Roles v2**
- 18+ condition operators, nested AND/OR, array conditions
- Auto-replenishing allowances, built-in EqualToAvatar
- No other system matches this out-of-the-box

### If your priority is **MULTI-CHAIN / CHAIN ABSTRACTION**:
**C: Kernel (ZeroDev)** or **G: Kernel + Intent**
- Native multi-chain validators, chain-agnostic signatures
- ZeroDev CAB (Chain Abstraction Bundle) via ERC-7683

---

## 9. Cross-Cutting Findings

### Finding 1: No Timelock Exists Off-The-Shelf (Except Zodiac Delay)
Every architecture except A requires custom timelock development. ColdStorageHook (Rhinestone) is too restrictive for our use case. This is a **competitive differentiator** for our project.

### Finding 2: ERC-7579 Is Winning the Standards War
ERC-7579 has been adopted by Safe, Kernel, Biconomy, OKX, Etherspot, Thirdweb. ERC-6900 (Alchemy) has narrower adoption. Building on ERC-7579 is the safest bet.

### Finding 3: EIP-7702 Changes the Game for Single-Owner Accounts
Post-Pectra (May 2025), every major AA provider supports 7702. For single-owner managed accounts, 7702+7579 is the state-of-the-art: no deployment, same module ecosystem, best gas efficiency.

### Finding 4: Session Keys + Zodiac Roles = Best of Both Worlds
Zodiac Roles v2 has the most expressive conditions but no 4337 integration. SmartSession has native 4337 but limited conditions. A hybrid (both on the same Safe) could leverage the strengths of each.

### Finding 5: Intent-Based Execution Is the Next Frontier
Glider.fi validates the pattern (Kernel + intents + solvers). Not needed for MVP, but should be the v2 evolution for swap/rebalancing operations. CoW Protocol integration provides immediate intent support.

---

## 10. Existing Product Lessons

| Product | Architecture | TVL | Key Lesson |
|---------|-------------|-----|------------|
| **Brahma.fi** | Safe + Sub-Safes + Guards | $200M+ | Hierarchical Safe model works; off-chain policy is pragmatic but adds trust |
| **Glider.fi** | Kernel + Session Keys + Intents | Early (a16z seed) | Validates Kernel for consumer DeFi; lacks institutional safety mechanisms |
| **Instadapp** | Custom DSA + Connectors | ~$2B | Connector abstraction maps to ERC-7579 executors; authority model too coarse |
| **Enzyme Finance** | Custom Vaults + On-chain Policies | $500M+ | Best on-chain policy system; proves complex policies are feasible |
| **Euler V2** | EVC + Operators + Lockdown | Growing | Elegant sub-account + operator delegation; lockdown mode is unique safety feature |
| **Yearn V3** | Role-based Bitmask | $500M+ | Compact role permissions via bitmask; practical for DeFi vaults |
