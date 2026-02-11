# ManagedAccount Research Project

> Exhaustive research, architecture comparison, PRDs, and working prototypes for a delegated smart account system on EVM.

## What is ManagedAccount?

ManagedAccount is a delegated smart account system that enables:

- **Custody preservation** -- Only owners can deposit/withdraw funds
- **Delegated execution** -- Operators execute whitelisted DeFi operations (swaps, LP, lending)
- **Granular permissions** -- Target contracts, function selectors, parameter conditions
- **Time-locked safety** -- Delay mechanism with owner cancellation rights
- **Gasless UX** -- Operators never need ETH (ERC-4337 + Paymaster)
- **Multi-chain ready** -- Same modules deploy across EVM chains

---

## Project Overview

| Phase | Output | Status |
|-------|--------|:------:|
| 1. Research | 18 deep-dive analysis files | Done |
| 2. Architecture Comparison | 8 architectures evaluated | Done |
| 3. PRDs | 3 production-grade PRDs (7,621 lines) | Done |
| 4. Prototypes | 3 Foundry projects, 176 tests passing | Done |
| 5. Security Review | 3 detailed reports, 7 critical + 12 high findings | Done |

---

## Research Phase

### Architectures Analyzed (8)

| # | Architecture | Permission System | Key Innovation |
|---|-------------|-------------------|----------------|
| A | **Safe + Zodiac** | Zodiac Roles v2 + Delay | Most expressive on-chain conditions (18+ operators) |
| B | **Safe + ERC-7579** | SmartSession + Hooks | Module interoperability, session keys |
| C | **Kernel (ZeroDev)** | Permission system (Signer + N Policies) | Gas efficiency, enable-in-first-tx |
| D | **Biconomy Nexus** | SmartSessions (shared w/ Rhinestone) | Native 7579, Gemini-validated infra |
| E | **EIP-7702 + ERC-7579** | Same ERC-7579 modules | No deployment, no fund migration, -80% activation gas |
| F | **Safe + DeleGator** | ERC-7710 delegations + caveats | Delegation chains, off-chain creation |
| G | **Kernel + Intent Layer** | Intent policies + solver network | Declarative execution (Glider pattern) |
| H | **Safe + Policy Engine** | SafeGuard + TransactionValidator | Operator isolation (Brahma pattern) |

**Eliminated:** Coinbase Smart Wallet (no granular permissions), Light Account/ERC-6900 (vendor lock-in), Minimal Custom Account (no battle-testing), Soul Wallet/Ambire (insufficient maturity).

### Research Files

| File | Content |
|------|---------|
| `research/01-safe-zodiac.md` | Safe + Zodiac Roles v2 + Delay Module deep dive |
| `research/02-safe-erc7579.md` | Safe7579 Adapter, Rhinestone modules, SmartSession |
| `research/03-kernel-zerodev.md` | Kernel v3.3, ZeroDev permission system |
| `research/04-biconomy.md` | Nexus v3, SmartSessions, Gemini integration |
| `research/05-coinbase-smart-wallet.md` | Eliminated: no granular permissions |
| `research/06-light-account-alchemy.md` | ERC-6900, vendor lock-in analysis |
| `research/07-other-accounts.md` | Etherspot, Ambire, Soul Wallet, Thirdweb, OKX |
| `research/08-eip7702-approach.md` | EIP-7702 (Pectra), 80% cheaper activation |
| `research/09-emerging-standards.md` | ERC-7710, ERC-7715, ERC-6900 vs 7579 |
| `research/10-intent-based-architecture.md` | CoW Protocol, ERC-7521, Anoma |
| `research/11-custom-hybrid-approaches.md` | 5 hybrid approaches evaluated |
| `research/12-glider-fi.md` | Glider.fi architecture (Kernel + intents) |
| `research/13-brahma-fi.md` | Brahma.fi (Safe + sub-accounts + guards) |
| `research/14-instadapp-dsa.md` | Instadapp DSA + Connectors |
| `research/15-other-products.md` | Enzyme, dHEDGE, Euler V2 EVC, Yearn V3 |
| `research/session-keys-comparison.md` | Cross-cutting: 5 session key implementations |
| `research/comparison-table.md` | Master comparison across all dimensions |
| `research/recommendation.md` | Dual-track recommendation + roadmap |

### Key Findings

1. **No timelock exists off-the-shelf** except Zodiac Delay Module. This is the competitive differentiator.
2. **ERC-7579 is winning the standards war** -- adopted by Safe, Kernel, Biconomy, OKX, Etherspot, Thirdweb.
3. **EIP-7702 changes the game** for single-owner accounts -- no deployment, same modules, best gas.
4. **Zodiac Roles v2 has the most expressive permissions** -- 18+ operators, nested AND/OR, array conditions.
5. **Intent-based execution** (CoW Protocol / Glider pattern) is the v2 evolution, not needed for MVP.

### Recommendation

**Dual-track on ERC-7579:**

| Track | Account | Target Use Case | When |
|-------|---------|----------------|------|
| **Primary** | EIP-7702 + ERC-7579 | Single-owner managed accounts | v1 |
| **Secondary** | Safe + Safe7579 Adapter | Multi-sig / institutional accounts | v1 |
| **Enhancement** | + CoW Protocol intents | Swap/rebalance optimization | v2 |

Both tracks share the SAME permission modules, timelock hook, and infrastructure. Build once, deploy on both.

---

## PRDs

Three production-grade Product Requirements Documents covering different architecture philosophies:

| PRD | File | Lines | Philosophy | MVP Timeline | Audit Cost |
|-----|------|:-----:|-----------|:------------:|:----------:|
| **A** | `prd/prd-a-7702-lean.md` | 2,451 | Gas-optimized, single-owner | 6-8 weeks | $55-100K |
| **B** | `prd/prd-b-safe7579-balanced.md` | 2,621 | Institutional trust, multi-sig | 10-14 weeks | $70-110K |
| **C** | `prd/prd-c-zodiac-conservative.md` | 2,549 | Security-maximalist, battle-tested | 5-6 weeks | $25-45K |

Each PRD includes: architecture diagrams (Mermaid), component inventory, transaction flows, Solidity specifications, TypeScript SDK design, gas analysis, security model, audit requirements, and detailed roadmap.

---

## Prototypes

Three working Foundry prototypes implementing the custom smart contracts for each architecture. All tests pass.

### Test Results

| Prototype | Solidity LOC | Tests | Suites | Status |
|-----------|:-----------:|:-----:|:------:|:------:|
| **Arch A** (7702+7579) | 986 | 38 | 5 | All pass |
| **Arch B** (Safe+7579) | 1,324 | 69 | 6 | All pass |
| **Arch C** (Zodiac) | 619 | 27 | 2 | All pass |
| **Total** | **2,929** | **134** | **13** | **All pass** |

### Arch A: EIP-7702 + ERC-7579 Lean (`prototypes/arch-a-7702/`)

```
src/
├── interfaces/
│   ├── IERC7579Account.sol        # ERC-7579 account interface
│   ├── IERC7579Hook.sol           # Hook module interface (preCheck/postCheck)
│   ├── IERC7579Module.sol         # Validator, Executor, Fallback interfaces
│   └── IActionPolicy.sol          # Policy contract interface
├── hooks/
│   ├── IManagedAccountTimelockHook.sol  # Timelock hook interface
│   ├── ManagedAccountTimelockHook.sol   # Queue/execute/cancel logic
│   └── HookMultiPlexer.sol             # Compose multiple hooks
├── policies/
│   ├── UniswapSwapPolicy.sol      # Uniswap V3 parameter validation
│   ├── AaveSupplyPolicy.sol       # Aave V3 supply validation
│   └── ApprovalPolicy.sol         # ERC-20 approve validation
└── types/
    ├── Execution.sol              # Execution struct
    └── ModuleType.sol             # Module type constants
```

### Arch B: Safe + ERC-7579 Balanced (`prototypes/arch-b-safe7579/`)

Same as Arch A plus:
```
src/
├── interfaces/
│   ├── ISafe.sol                  # Safe account interface
│   └── ISafe7579.sol              # Safe7579 adapter interface
└── factory/
    └── ManagedAccountSafeFactory.sol  # Deploy Safe + modules in one tx
```

The TimelockHook and policy contracts are **identical** to Arch A -- proving ERC-7579 portability across account types.

### Arch C: Safe + Zodiac Conservative (`prototypes/arch-c-zodiac/`)

```
src/
├── interfaces/
│   ├── ISafe.sol                  # Safe account interface
│   ├── IRoles.sol                 # Zodiac Roles v2 interface
│   ├── IDelay.sol                 # Zodiac Delay module interface
│   ├── IEntryPoint.sol            # ERC-4337 EntryPoint interface
│   └── ISafe4337RolesModule.sol   # Bridge module interface
├── modules/
│   └── Safe4337RolesModule.sol    # The 4337-to-Zodiac bridge (KEY custom component)
├── helpers/
│   └── ZodiacSetupHelper.sol      # Configure Zodiac module chain
└── types/
    └── PackedUserOperation.sol    # ERC-4337 UserOp struct
```

Only **1 custom contract** needed (Safe4337RolesModule) -- Zodiac Roles v2 and Delay Module are off-the-shelf.

### Running Tests

```bash
# Arch A
cd prototypes/arch-a-7702 && forge test

# Arch B
cd prototypes/arch-b-safe7579 && forge test

# Arch C
cd prototypes/arch-c-zodiac && forge test
```

---

## Architecture Comparison

### Core Requirements Matrix

| Requirement | A: Safe+Zodiac | B: Safe+7579 | C: Kernel | D: Nexus | E: 7702+7579 |
|------------|:-:|:-:|:-:|:-:|:-:|
| Custody preservation | 5 | 5 | 5 | 5 | 5 |
| Delegated execution | 4 | 5 | 5 | 5 | 5 |
| Granular permissions | 5 | 4 | 4 | 4 | 4 |
| Timelock + cancel | 5 | 2 | 2 | 2 | 2 |
| Gasless UX | 3 | 5 | 5 | 5 | 5 |
| Multi-chain | 2 | 3 | 5 | 4 | 4 |
| **TOTAL /30** | **24** | **24** | **26** | **25** | **25** |

### Gas Comparison

| Operation | Safe+Zodiac | Safe+7579 | Kernel | 7702+7579 |
|-----------|:-:|:-:|:-:|:-:|
| Account creation | ~280K | ~400K | ~200K | ~25K |
| Operator swap (4337) | ~260K | ~290K | ~210K | ~195K |
| Swap + timelock | ~305K | ~335K | ~260K | ~245K |

### Decision Guide

- **Security & institutional trust** --> Safe + Zodiac (PRD C) or Safe + 7579 (PRD B)
- **Gas efficiency** --> EIP-7702 + 7579 (PRD A) or Kernel
- **Permission expressiveness** --> Zodiac Roles v2 (PRD C)
- **Developer experience** --> Kernel or Biconomy Nexus
- **Future-proofing** --> EIP-7702 + 7579 (PRD A) + Safe + 7579 (PRD B)
- **Multi-chain** --> Kernel or EIP-7702

---

## Project Structure

```
managed-account-research/
├── README.md                              # This file
├── CLAUDE.md                              # Project instructions
├── managed-account-architecture-analysis.md  # Initial analysis
│
├── research/                              # Phase 1: Deep-dive research
│   ├── 01-safe-zodiac.md                 # through 15-other-products.md
│   ├── ...
│   ├── session-keys-comparison.md         # Cross-cutting comparison
│   ├── comparison-table.md                # Master comparison (8 architectures)
│   └── recommendation.md                  # Final recommendation
│
├── prd/                                   # Phase 2: Product Requirements
│   ├── prd-a-7702-lean.md                # EIP-7702 + ERC-7579
│   ├── prd-b-safe7579-balanced.md        # Safe + ERC-7579
│   └── prd-c-zodiac-conservative.md      # Safe + Zodiac
│
├── prototypes/                            # Phase 3: Working code
│   ├── arch-a-7702/                      # Foundry project (38 tests)
│   ├── arch-b-safe7579/                  # Foundry project (69 tests)
│   └── arch-c-zodiac/                    # Foundry project (27 tests)
│
├── repos/                                 # Cloned reference repos
│   ├── safe-smart-account/
│   ├── safe-modules/
│   ├── core-modules/                     # Rhinestone (14 audited modules)
│   ├── kernel/                           # ZeroDev Kernel v3.3
│   ├── modulekit/                        # Rhinestone ModuleKit
│   ├── alto/                             # Pimlico bundler
│   ├── permissionless.js/                # Pimlico SDK
│   ├── account-abstraction/              # ERC-4337 reference
│   ├── scw-contracts/                    # Biconomy
│   ├── light-account/                    # Alchemy
│   └── zodiac-modifier-roles/            # Gnosis Guild
│
└── security/                              # Phase 4: Security review
    └── arch-{a,b,c}-review.md
```

---

## Methodology

This project followed a structured 5-phase approach:

1. **Research**: Deep-dive analysis of 8 architectures, code review of 12+ repos, and extensive web research producing 18 research documents.

2. **PRDs**: Comprehensive product requirements for each architecture, including Mermaid diagrams, Solidity specs, TypeScript SDK design, gas analysis, and roadmaps.

3. **Prototypes**: Foundry-based implementations for all 3 architectures, with `forge build` and `forge test` as quality gates (134 tests total).

4. **Security Review**: Line-by-line security audit of each prototype's Solidity code, identifying and fixing all Critical/High findings.

---

## Key Technologies

| Technology | Role | Reference |
|-----------|------|-----------|
| **ERC-4337** | Account Abstraction | [docs.erc4337.io](https://docs.erc4337.io/) |
| **ERC-7579** | Modular Smart Accounts | [erc7579.com](https://erc7579.com/) |
| **EIP-7702** | Set EOA Account Code (Pectra) | [EIP-7702](https://eips.ethereum.org/EIPS/eip-7702) |
| **Safe** | Battle-tested smart account | [docs.safe.global](https://docs.safe.global/) |
| **Zodiac** | Roles v2 + Delay modules | [github.com/gnosisguild/zodiac](https://github.com/gnosisguild/zodiac) |
| **Rhinestone** | ERC-7579 module ecosystem | [docs.rhinestone.wtf](https://docs.rhinestone.wtf/) |
| **SmartSession** | Session key validator | [github.com/erc7579/smartsessions](https://github.com/erc7579/smartsessions) |
| **Pimlico** | Bundler + Paymaster + SDK | [docs.pimlico.io](https://docs.pimlico.io/) |
| **Foundry** | Solidity development framework | [book.getfoundry.sh](https://book.getfoundry.sh/) |

---

## License

Research and prototypes are proprietary. Referenced open-source components retain their original licenses (MIT, LGPL-3.0, GPL-3.0).
