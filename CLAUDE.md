# CLAUDE.md — ManagedAccount Research Project

## Project Context

We're researching implementation options for **ManagedAccount**, a delegated smart account system that enables:
- **Custody preservation**: Only owners can deposit/withdraw funds
- **Delegated execution**: Operators can execute whitelisted DeFi operations
- **Granular permissions**: Target contracts, function selectors, parameter conditions
- **Time-locked safety**: Delay module with owner cancellation rights

Reference documents:
- `managed-account-architecture-analysis.md` — Architecture comparison (3 options analyzed)

## Research Objectives

1. **Deep dive into each architecture option**:
   - A: Safe + Zodiac Modules (as specified)
   - B: Safe + ERC-7579 (recommended)
   - C: Kernel/ZeroDev

2. **Evaluate infrastructure choices**:
   - Bundlers: Pimlico Alto, Alchemy Rundler, self-hosted
   - Paymasters: Pimlico, Coinbase, custom
   - RPC: eRPC, Alchemy, Infura

3. **Prototype key components**:
   - Permission system comparison
   - Session key implementations
   - Delay/timelock mechanisms

## Key Technologies to Research

### ERC-4337 (Account Abstraction)
- UserOperation structure
- EntryPoint contract
- Bundler mechanics
- Paymaster patterns

### ERC-7579 (Modular Smart Accounts)
- Module types: Validator, Executor, Fallback, Hook
- Safe7579 Adapter
- Rhinestone modules ecosystem
- Module Registry

### Smart Account Implementations
- Safe (Gnosis Safe)
- Kernel (ZeroDev)
- Biconomy Smart Account
- Coinbase Smart Wallet

### Permission/Delegation Standards
- ERC-7710 (Delegation)
- ERC-7715 (Permission Requests)
- Session Keys patterns
- Zodiac Roles module

## Research Tasks

### Phase 1: Documentation Deep Dive
```bash
# Clone and explore key repos
git clone https://github.com/safe-global/safe-smart-account
git clone https://github.com/safe-global/safe-modules
git clone https://github.com/rhinestonewtf/core-modules
git clone https://github.com/zerodevapp/kernel
git clone https://github.com/pimlicolabs/alto
git clone https://github.com/pimlicolabs/permissionless.js
git clone https://github.com/gnosisguild/zodiac-modifier-roles
git clone https://github.com/gnosisguild/zodiac-module-delay
```

### Phase 2: Code Analysis
- Compare permission models across implementations
- Analyze gas costs for different architectures
- Study upgrade patterns and security considerations

### Phase 3: Prototyping
- Minimal PoC for each architecture
- Permission configuration examples
- Integration with Pimlico testnet

## Key Questions to Answer

### Architecture
- [ ] How does Safe7579 Adapter work internally?
- [ ] How to implement Delay Module equivalent in ERC-7579?
- [ ] Kernel vs Safe: gas comparison for common operations?
- [ ] How does Glider.fi implement their permission system?

### Permissions
- [ ] Session keys vs Zodiac Roles: feature parity?
- [ ] How to enforce "recipient must be Safe address" rule in each system?
- [ ] Parameter condition types available in each implementation?

### Infrastructure
- [ ] Self-hosted Alto vs Pimlico API: tradeoffs?
- [ ] How to implement gasless UX with each architecture?
- [ ] Multi-chain deployment strategies?

### Security
- [ ] Audit status of each component?
- [ ] Emergency procedures comparison?
- [ ] Module upgrade risks?

## Useful Commands

```bash
# Search for permission-related code
rg -t solidity "permission|session|delegate" --glob "*.sol"

# Find ERC-7579 module implementations
fd "Module.sol" --type f

# Analyze Safe module interfaces
ast-grep --pattern 'function execTransactionFromModule'

# Check gas usage in tests
rg "gasUsed|gas:" --glob "*.t.sol"
```

## Reference Links

### Documentation
- https://docs.safe.global/advanced/erc-7579/overview
- https://docs.pimlico.io/
- https://docs.zerodev.app/
- https://docs.rhinestone.wtf/modulekit
- https://erc7579.com/
- https://docs.erc4337.io/

### Key Repos
- https://github.com/eth-infinitism/account-abstraction (ERC-4337 reference)
- https://github.com/safe-global/safe-modules (Safe7579 Adapter)
- https://github.com/rhinestonewtf/core-modules (14 audited modules)
- https://github.com/gnosisguild/zodiac (Roles + Delay modules)
- https://github.com/glider-fi (Glider's forks for reference)

### Articles & Analysis
- https://blog.anagram.xyz/glider/ (Glider architecture)
- https://safe.global/blog/launching-erc-7579-adapter-for-safe
- https://blog.thirdweb.com/erc-4337-vs-native-account-abstraction-vs-eip-7702-developer-guide-2025/

## Project Structure (Suggested)

```
managed-account-research/
├── CLAUDE.md                          # This file
├── docs/
│   ├── ManagedAccounts.pdf            # Original spec
│   ├── architecture-analysis.md       # Comparison doc
│   └── research-notes/
│       ├── safe-7579.md
│       ├── kernel-zerodev.md
│       ├── zodiac-modules.md
│       └── permission-models.md
├── repos/                             # Cloned repos for analysis
│   ├── safe-modules/
│   ├── core-modules/
│   ├── kernel/
│   └── zodiac/
├── prototypes/
│   ├── safe-zodiac/                   # Architecture A prototype
│   ├── safe-7579/                     # Architecture B prototype
│   └── kernel/                        # Architecture C prototype
└── analysis/
    ├── gas-comparison.md
    ├── permission-mapping.md
    └── security-review.md
```

## Research Guidelines

When researching:
1. **Prioritize official docs** over blog posts
2. **Check audit reports** for security-critical components
3. **Compare code, not just docs** — implementations differ
4. **Track gas costs** — important for production viability
5. **Note breaking changes** — AA ecosystem evolves fast

When prototyping:
1. Use **Foundry** for smart contract work
2. Use **permissionless.js** for TypeScript integration
3. Test on **Sepolia** with Pimlico's free tier
4. Document all assumptions and limitations

## Current Status

- [x] Initial architecture analysis complete
- [ ] Deep dive Safe7579 Adapter
- [ ] Deep dive Kernel permissions
- [ ] Deep dive Zodiac Roles v2
- [ ] Gas benchmarks
- [ ] Security comparison
- [ ] PoC implementations
