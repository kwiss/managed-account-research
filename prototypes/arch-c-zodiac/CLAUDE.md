# Dev Instructions — Arch C: Safe + Zodiac Prototype

Development guidelines for the Solidity smart contracts of this delegated smart account system.

## Project Context

This is a Foundry project implementing the custom smart contracts for **Architecture C: Safe + Zodiac Roles v2 + Delay Module (Conservative / Battle-Tested)** of the ManagedAccount system.

The ManagedAccount enables:
- **Custody preservation**: Safe multi-sig holds all funds
- **Delegated execution**: Operators authenticated via Safe4337RolesModule, routed through Zodiac Roles v2
- **Granular permissions**: Zodiac Roles v2 (18+ condition operators, most expressive system)
- **Time-locked safety**: Zodiac Delay Module (off-the-shelf FIFO queue with cooldown + owner cancel)
- **Gasless UX**: Custom Safe4337RolesModule bridges ERC-4337 to Zodiac pipeline

Key difference: This is the ONLY architecture where the timelock (Zodiac Delay) and permissions (Zodiac Roles v2) are BOTH off-the-shelf. The ONLY custom contract needed is Safe4337RolesModule — the bridge between ERC-4337 UserOps and the Zodiac pipeline.

## Module Chain

```
Operator signs UserOp → EntryPoint → Safe4337RolesModule.validateUserOp() (ECDSA verify)
                                    → Safe4337RolesModule.executeUserOp()
                                    → IRoles.execTransactionWithRole() (permission check)
                                    → IDelay.execTransactionFromModule() (queue with cooldown)
                                    → ISafe.execTransactionFromModule() (execute)
```

## Tech Stack

- **Solidity ^0.8.24** (Foundry)
- **forge-std** for testing
- Zodiac interfaces (IRoles, IDelay) — defined inline
- Safe interfaces (ISafe) — defined inline
- ERC-4337 types (PackedUserOperation) — defined inline

## Quality Checks

```bash
source ~/.zshenv && forge build
source ~/.zshenv && forge test
```

## Your Task

1. Read `prd.json` in this directory
2. Read `progress.txt` (check Codebase Patterns section first)
3. Check you're on the correct branch. If not, create it from main.
4. Pick the **highest priority** story where `passes: false`
5. Implement that single story
6. Run quality checks
7. Commit: `feat: [Story ID] - [Story Title]`
8. Update `prd.json` to set `passes: true`
9. Append progress to `progress.txt`

## Solidity Patterns

- Use `pragma solidity ^0.8.24;`
- Custom errors, events, NatSpec
- Interfaces in `src/interfaces/`
- Module in `src/modules/`
- Helpers in `src/helpers/`
- Tests in `test/`, mocks in `test/mocks/`
- Use ECDSA recovery for operator signature verification
- Use transient storage (tstore/tload) to pass operator context from validation to execution

## Important Notes

- Remove default Counter files if they exist
- Do NOT install external dependencies
- The key custom contract is Safe4337RolesModule (~300-500 LOC)
- Mock contracts for Roles/Delay/Safe are needed for testing
- Focus on the bridge logic, not on reimplementing Zodiac internals

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
