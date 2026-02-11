# Dev Instructions — Arch A: EIP-7702 + ERC-7579 Prototype

Development guidelines for the Solidity smart contracts of this delegated smart account system.

## Project Context

This is a Foundry project implementing the custom smart contracts for **Architecture A: EIP-7702 + ERC-7579 (Lean / Gas-Optimized)** of the ManagedAccount system.

The ManagedAccount enables:
- **Custody preservation**: Only owners can deposit/withdraw
- **Delegated execution**: Operators execute whitelisted DeFi ops via session keys
- **Granular permissions**: Policy contracts validate parameters
- **Time-locked safety**: ManagedAccountTimelockHook queues operator ops with delay + owner cancel
- **Gasless UX**: ERC-4337 + Paymaster

## Tech Stack

- **Solidity ^0.8.24** (Foundry)
- **forge-std** for testing
- **ERC-7579 module interfaces** (Validator, Executor, Hook, Fallback)
- No external dependencies beyond forge-std (we define our own interfaces)

## Quality Checks

Run these before committing:
```bash
source ~/.zshenv && forge build
source ~/.zshenv && forge test
```

Both must pass. If forge test fails, fix the failing tests before committing.

## Your Task

1. Read `prd.json` in this directory
2. Read `progress.txt` (check Codebase Patterns section first)
3. Check you're on the correct branch from PRD `branchName`. If not, create it from main.
4. Pick the **highest priority** user story where `passes: false`
5. Implement that single user story
6. Run `source ~/.zshenv && forge build` and `source ~/.zshenv && forge test`
7. If checks pass, commit ALL changes: `feat: [Story ID] - [Story Title]`
8. Update `prd.json` to set `passes: true` for the completed story
9. Append progress to `progress.txt`

## Solidity Patterns

- Use `pragma solidity ^0.8.24;`
- Use custom errors (not require strings) for gas efficiency
- Use events for all state changes
- Use NatSpec comments on public functions
- Interfaces go in `src/interfaces/`
- Implementations go in `src/hooks/`, `src/policies/`, etc.
- Tests go in `test/` with `.t.sol` suffix
- Use `forge-std/Test.sol` for test base

## Important Notes

- Remove the default `src/Counter.sol`, `test/Counter.t.sol`, and `script/Counter.s.sol` if they exist
- Do NOT install external dependencies (no forge install). Define interfaces inline.
- Each story should be completable in one iteration
- Focus on correctness, not gas optimization

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
