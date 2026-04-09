# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Layout

- `/README.md` - the ERC specification / design document for the Warden pattern
- `/contracts/` - Solidity contracts
- `/test/` - JavaScript test suite
- `/ignition/` - Hardhat Ignition deployment modules

All commands below should be run from the repo root.

## Commands

```bash
npm test               # lint + full test suite (bail on first failure)
npm run lint           # solhint on contracts/
npm run format         # Prettier + solidity plugin (in-place)
npm run format:check   # formatting check without modifying files
npm run compile        # Hardhat compile

# Single test file
npx hardhat test test/Warden.tests.js

# Local dev node with contracts deployed
npm start

# Deployment
npm run deploy -- --network <localhost|devnet|testnet>
npm run deploy -- --network <name> --reset   # wipe and redeploy

# Formal verification (requires Certora toolchain)
npm run verify                 # all specs
npm run verify:marketplace     # Marketplace.spec only
npm run verify:state_changes   # StateChanges.spec only

npm run coverage               # Istanbul coverage report
npm run gas:report             # Gas usage report
```

## Architecture

### Core Pattern: Warden + Controller

The Warden separates **token custody** from **business logic**. Controllers (e.g. `Marketplace`) never hold tokens; they instruct the Warden to move tokens between internal accounts.

```
Marketplace (controller)
    │  delegates token operations to
    ▼
Warden (custody enforcement)
    │  holds ERC20 tokens for
    ▼
Fund → Account hierarchy
```

### Fund / Account Hierarchy

- **Fund**: top-level custody unit owned by a controller. Has a lifecycle (Inactive → Locked → Withdrawing or Frozen → Withdrawing) and two time parameters: `lockExpiry` (when withdrawal can begin) and `lockMaximum` (upper bound used for solvency checking).
- **Account**: subdivision of a Fund. Identified by a `bytes32 AccountId` encoding a 20-byte holder address + 12-byte discriminator. Each account tracks `available` balance and `designated` (committed, non-transferable) balance.

### Token Operations (all called by the controller)

| Operation | Effect |
|-----------|--------|
| `lock` / `extendLock` | Activate a fund and set time windows |
| `deposit` | Move ERC20 tokens in from caller → account |
| `transfer` | Redistribute available (non-designated) tokens between accounts |
| `designate` | Irreversibly commit available tokens to the account holder |
| `burnDesignated` / `burnAccount` | Destroy tokens (slashing) |
| `freezeFund` | Seal account balances - no further transfers, designations, deposits, or burns until the fund unlocks and withdrawals begin |
| `withdraw` / `withdrawByRecipient` | Transfer tokens out after lock expires |

### Core Invariant (enforced in `WardenBase.sol`)

- **Lock**: `fund.lockExpiry ≤ fund.lockMaximum`

### Key Files

| File | Purpose |
|------|---------|
| `contracts/Warden.sol` | Public interface - thin wrapper exposing WardenBase operations |
| `contracts/warden/WardenBase.sol` | Core state machine: fund/account tracking, invariant enforcement |
| `contracts/warden/Accounts.sol` | `AccountId` encoding/decoding (holder + discriminator) |
| `contracts/warden/Funds.sol` | Fund state and lifecycle transitions |
| `contracts/Timestamps.sol` | `Timestamp` value type and `currentTime()` helper |
| `contracts/TestToken.sol` | Minimal ERC20 used in tests |
| `ignition/modules/warden.js` | Deployment: Token → Warden |

### Custom Types

Solidity 0.8.28 user-defined value types are used throughout:
`FundId` (bytes32), `AccountId` (bytes32), `Controller` (address), `Timestamp` (uint40)

## Toolchain

- Solidity 0.8.28, EVM target: Paris, optimizer: 1000 runs
- OpenZeppelin ^5.3.0 for ERC20
- Hardhat ^2.28.3 + Ignition for deployment
- Tests: JavaScript + Chai/Mocha (30s timeout)
- Formatting: Prettier + prettier-plugin-solidity (2-space indent)
- Linting: solhint (private vars must start with `_`, visibility explicit)
