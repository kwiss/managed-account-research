# Dev Instructions — Arch B: Safe + ERC-7579 Prototype

Development guidelines for the Solidity smart contracts of this delegated smart account system.

## Project Context

This is a Foundry project implementing the custom smart contracts for **Architecture B: Safe + ERC-7579 + SmartSession (Balanced / Institutional)** of the ManagedAccount system.

The ManagedAccount enables:
- **Custody preservation**: Safe multi-sig (n-of-m) holds all funds
- **Delegated execution**: Operators use SmartSession session keys via Safe7579 Adapter
- **Granular permissions**: Policy contracts validate parameters
- **Time-locked safety**: ManagedAccountTimelockHook (same as Arch A, ERC-7579 portable)
- **Gasless UX**: ERC-4337 + Paymaster via Safe7579

Key difference from Arch A: This uses Safe as the account base, with Safe7579 Adapter bridging to ERC-7579 modules. The ManagedAccountSafeFactory orchestrates deployment.

## Tech Stack

- **Solidity ^0.8.24** (Foundry)
- **forge-std** for testing
- **ERC-7579 module interfaces** + **Safe interfaces** (ISafe, ISafe7579)
- No external dependencies beyond forge-std (we define our own interfaces)

## Quality Checks

Run these before committing:
```bash
source ~/.zshenv && forge build
source ~/.zshenv && forge test
```

Both must pass.

## Your Task

1. Read `prd.json` in this directory
2. Read `progress.txt` (check Codebase Patterns section first)
3. Check you're on the correct branch from PRD `branchName`. If not, create it from main.
4. Pick the **highest priority** user story where `passes: false`
5. Implement that single user story
6. Run quality checks
7. If checks pass, commit: `feat: [Story ID] - [Story Title]`
8. Update `prd.json` to set `passes: true`
9. Append progress to `progress.txt`

## Solidity Patterns

- Use `pragma solidity ^0.8.24;`
- Custom errors, events, NatSpec
- Interfaces in `src/interfaces/`
- Hooks in `src/hooks/`, policies in `src/policies/`, factory in `src/factory/`
- Tests in `test/` with `.t.sol` suffix
- The TimelockHook and policies MUST be identical to Arch A (proving ERC-7579 portability)
- The ManagedAccountSafeFactory is unique to this architecture

## Important Notes

- Remove default Counter files if they exist
- Do NOT install external dependencies
- Define all interfaces inline
- Focus on correctness

## Progress Report Format

APPEND to progress.txt:
```
## [Date] - [Story ID]
- What was implemented
- Files changed
- **Learnings:**
  - Patterns discovered
  - Gotchas encountered
---
```

## Stop Condition

If ALL stories have `passes: true`, reply with: <promise>COMPLETE</promise>
