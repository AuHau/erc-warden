# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Layout

This repo has two layers:
- `/README.md` — the ERC specification / design document for the Vault pattern
- `/archivist-contracts/` — the Hardhat implementation (all development happens here)

All commands below should be run from `archivist-contracts/`.

## Commands

```bash
npm test               # lint + full test suite (bail on first failure)
npm run lint           # solhint on contracts/
npm run format         # Prettier + solidity plugin (in-place)
npm run format:check   # formatting check without modifying files
npm run compile        # Hardhat compile

# Single test file
npx hardhat test test/Vault.tests.js

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

### Core Pattern: Vault + Controller

The Vault separates **token custody** from **business logic**. Controllers (e.g. `Marketplace`) never hold tokens; they instruct the Vault to move tokens between internal accounts.

```
Marketplace (controller)
    │  delegates token operations to
    ▼
Vault (custody enforcement)
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
| `flow` | Set continuous per-second payment stream between accounts; incoming immediately becomes designated |
| `burnDesignated` / `burnAccount` | Destroy tokens (slashing) |
| `freezeFund` | Emergency halt — freezes all flows |
| `withdraw` / `withdrawByRecipient` | Transfer tokens out after lock expires |

### Three Critical Invariants (enforced in `VaultBase.sol`)

1. **Lock**: `fund.lockExpiry ≤ fund.lockMaximum`
2. **Solvency**: `flow.outgoing × (fund.lockMaximum − flow.updated) ≤ balance.available` — the fund can cover all outgoing flows until lockMaximum
3. **Flow Conservation**: Σ incoming flows = Σ outgoing flows per fund

### Key Files

| File | Purpose |
|------|---------|
| `contracts/Vault.sol` | Public interface — thin wrapper exposing VaultBase operations |
| `contracts/vault/VaultBase.sol` | Core state machine: fund/account tracking, invariant enforcement |
| `contracts/vault/Accounts.sol` | `AccountId` encoding/decoding (holder + discriminator) |
| `contracts/vault/Funds.sol` | Fund state and lifecycle transitions |
| `contracts/Marketplace.sol` | Reference controller: storage marketplace with clients, hosts, validators |
| `contracts/marketplace/VaultHelpers.sol` | Convenience wrappers that build AccountIds for marketplace roles |
| `contracts/marketplace/Collateral.sol` | Collateral designation/slashing logic |
| `contracts/Proofs.sol` | Groth16 ZK proof verification for storage proofs |
| `ignition/modules/marketplace.js` | Deployment order: Vault → Token → Verifier → Marketplace |
| `configuration/` | Per-network parameters (proof period, collateral ratios, etc.) |
| `certora/specs/` | Formal verification specs (Marketplace.spec, StateChanges.spec) |

### Custom Types

Solidity 0.8.28 user-defined value types are used throughout:
`FundId` (bytes32), `AccountId` (bytes32), `Controller` (address), `TokensPerSecond` (uint96)

### Lazy Flow Evaluation

Token flows (streaming payments) are **not executed each block**. Accumulated amounts are computed on-demand whenever state changes, keeping gas costs proportional to operations rather than time elapsed.

## Toolchain

- Solidity 0.8.28, EVM target: Paris, optimizer: 1000 runs
- OpenZeppelin ^5.3.0 for ERC20
- Hardhat ^2.28.3 + Ignition for deployment
- Tests: JavaScript + Chai/Mocha (30s timeout)
- Formatting: Prettier + prettier-plugin-solidity (2-space indent)
- Linting: solhint (private vars must start with `_`, visibility explicit)