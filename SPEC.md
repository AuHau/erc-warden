---
eip: XXXX
title: Secure Token Custody Vault
description: A standard interface for controller-scoped ERC-20 token custody with time-locked funds and account designation.
author: (@auhau)
discussions-to: https://ethereum-magicians.org/
status: Draft
type: Standards Track
category: ERC
created: 2026-04-07
requires: 20
---

## Abstract

This proposal defines a standard interface for a **Vault** — a smart contract that holds ERC-20 tokens on behalf of other smart contracts (called *controllers*). Controllers instruct the Vault to move tokens between internal accounts; they never hold tokens themselves. The Vault organises accounts into *funds* that carry a time-lock lifecycle. Tokens can be irreversibly committed to an account holder (*designation*) or destroyed (*burning*). The lock invariant is enforced at every state-changing operation.

## Motivation

Most DeFi contracts hold their own ERC-20 token balances. When a bug or exploit is found in the business logic, an attacker can often drain the entire balance in a single transaction. The Vault pattern introduces **defence in depth**: the token custody contract enforces invariants that constrain what even a fully compromised controller can do.

Concretely, the Vault addresses these threat scenarios:

- **Redirecting funds** — A time-lock prevents an attacker from withdrawing tokens immediately; by the time the lock expires, the balances are frozen in place.
- **Stealing collateral** — Designation makes tokens permanently committed to their rightful holder; no controller operation can transfer them away.
- **Blocking withdrawals** — Account holders can call `withdrawByRecipient` directly, bypassing the controller entirely.
- **Catastrophic partial compromise** — `freezeFund` halts operations and freezes balances at a known-good snapshot.

No existing ERC covers this combination of features. ERC-4626 targets yield-bearing vaults without controller/custody separation. ERC-6229 adds lock-in periods to ERC-4626 but serves a different purpose. ERC-7444 is a query-only maturity interface.

## Specification

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in RFC 2119 and RFC 8174.

### Types

A compliant Vault MUST expose the following user-defined types:

| Type | Underlying | Description |
|------|-----------|-------------|
| `FundId` | `bytes32` | Identifies a fund within a controller's namespace. Chosen by the controller. |
| `AccountId` | `bytes32` | Identifies an account. Encodes a 20-byte holder address (high bits) and a 12-byte discriminator (low bits). |

A compliant Vault MUST expose the following enum:

```solidity
enum FundStatus {
  Inactive,     // No lock set; no tokens held.
  Locked,       // Time-lock is active; controller operations are permitted.
  Frozen,       // Fund is halted; lock has not yet expired.
  Withdrawing   // Lock has expired; withdrawals are permitted.
}
```

### Controller Identity

The Vault uses `msg.sender` as the controller address for all fund-scoped operations. Each controller has an isolated namespace of funds; one controller cannot access another controller's funds.

### Account Identity

An `AccountId` MUST pack the holder address into the 20 high-order bytes and the discriminator into the 12 low-order bytes:

```
AccountId = bytes32(bytes20(holder)) | bytes32(uint256(uint96(discriminator)))
```

The holder address embedded in the `AccountId` is the only address to which tokens can be withdrawn from that account. The discriminator allows a single address to hold multiple independent accounts within the same fund.

A compliant Vault MUST provide encoding and decoding helpers:

```solidity
function encodeAccountId(address holder, bytes12 discriminator)
    external pure returns (AccountId);

function decodeAccountId(AccountId id)
    external pure returns (address holder, bytes12 discriminator);
```

### Fund Lifecycle

A fund progresses through states according to the following state machine:

```
Inactive ──lock()──► Locked ──lockExpiry passes──► Withdrawing
                       │
                   freezeFund()
                       │
                       ▼
                     Frozen ──lockExpiry passes──► Withdrawing
```

At any block, the effective status of a fund is derived from on-chain state as follows:

1. If `block.timestamp < fund.lockExpiry`:
   - If `fund.frozenAt != 0`: status is **Frozen**.
   - Otherwise: status is **Locked**.
2. If `fund.lockMaximum == 0`: status is **Inactive**.
3. Otherwise: status is **Withdrawing**.

A fund MUST begin in the `Inactive` state. The `Inactive` state means no lock has ever been set on that `(controller, fundId)` pair. Once a lock has been set, the `(controller, fundId)` pair MUST NOT transition back to `Inactive`, even if all account balances are zero. Reuse of a `FundId` by the same controller is therefore impossible after locking.

### Operations

#### `lock`

```solidity
function lock(FundId fundId, Timestamp expiry, Timestamp maximum) external;
```

Activates a fund by setting its time-lock parameters.

- MUST revert with `VaultFundAlreadyLocked` if the fund is not in `Inactive` state.
- MUST revert with `VaultInvalidExpiry` if `expiry > maximum`.
- On success: sets `fund.lockExpiry = expiry` and `fund.lockMaximum = maximum`. The fund transitions to `Locked`.

The `maximum` is an upper bound on any subsequent `extendLock` call. It MUST NOT be modified after `lock` is called.

#### `extendLock`

```solidity
function extendLock(FundId fundId, Timestamp expiry) external;
```

Pushes the lock expiry forward, for example to accommodate additional participants joining a deal.

- MUST revert with `VaultFundNotLocked` if the fund is not in `Locked` state.
- MUST revert with `VaultInvalidExpiry` if `expiry < fund.lockExpiry` (cannot move expiry backward).
- MUST revert with `VaultInvalidExpiry` if `expiry > fund.lockMaximum`.
- On success: sets `fund.lockExpiry = expiry`.

#### `deposit`

```solidity
function deposit(FundId fundId, AccountId accountId, uint128 amount) external;
```

Moves ERC-20 tokens from `msg.sender` into the Vault and credits the account's *available* balance.

- MUST revert with `VaultFundNotLocked` if the fund is not in `Locked` state.
- MUST transfer `amount` of the Vault's ERC-20 token from `msg.sender` to the Vault contract using `safeTransferFrom`. MUST revert if the transfer fails.
- On success: `account.balance.available += amount`.

#### `transfer`

```solidity
function transfer(FundId fundId, AccountId from, AccountId to, uint128 amount) external;
```

Moves available tokens between two accounts within the same fund. Only *available* tokens (not designated) can be transferred.

- MUST revert with `VaultFundNotLocked` if the fund is not in `Locked` state.
- MUST revert with `VaultInsufficientBalance` if `amount > sender.balance.available`.
- After the solvency check passes: `from.balance.available -= amount`, `to.balance.available += amount`.
- MUST enforce the account solvency invariant on the sending account after deduction (see Invariants).

#### `designate`

```solidity
function designate(FundId fundId, AccountId accountId, uint128 amount) external;
```

Irreversibly commits available tokens to the account holder. Once designated, tokens cannot be transferred to any other account.

- MUST revert with `VaultFundNotLocked` if the fund is not in `Locked` state.
- MUST revert with `VaultInsufficientBalance` if `amount > account.balance.available`.
- On success: `account.balance.available -= amount`, `account.balance.designated += amount`.

#### `burnDesignated`

```solidity
function burnDesignated(FundId fundId, AccountId accountId, uint128 amount) external;
```

Destroys a specified quantity of designated tokens from an account (penalty/slashing).

- MUST revert with `VaultFundNotLocked` if the fund is not in `Locked` state.
- MUST revert with `VaultInsufficientBalance` if `amount > account.balance.designated`.
- On success: `account.balance.designated -= amount`. The `amount` of tokens MUST be transferred to address `0x000000000000000000000000000000000000dEaD`.

#### `burnAccount`

```solidity
function burnAccount(FundId fundId, AccountId accountId) external;
```

Destroys the entire balance (available + designated) of an account.

- MUST revert with `VaultFundNotLocked` if the fund is not in `Locked` state.
- On success: deletes the account record and transfers `available + designated` tokens to address `0x000000000000000000000000000000000000dEaD`.

#### `freezeFund`

```solidity
function freezeFund(FundId fundId) external;
```

Immediately halts all controller operations on a fund until the lock expires naturally.

- MUST revert with `VaultFundNotLocked` if the fund is not in `Locked` state.
- On success: records `fund.frozenAt = block.timestamp`. The fund enters `Frozen` state.

#### `withdraw`

```solidity
function withdraw(FundId fundId, AccountId accountId) external;
```

Called by the controller to send an account's full balance to its holder.

- MUST revert with `VaultFundNotUnlocked` if the fund is not in `Withdrawing` state.
- Computes `amount = account.balance.available + account.balance.designated`.
- Deletes the account record (so a second `withdraw` call returns zero tokens).
- Transfers `amount` of the ERC-20 token to the holder address extracted from `accountId`.

#### `withdrawByRecipient`

```solidity
function withdrawByRecipient(
    Controller controller,
    FundId fundId,
    AccountId accountId
) external;
```

Called directly by the account holder, bypassing the controller. This is a critical safety escape hatch.

- MUST revert with `VaultOnlyAccountHolder` if `msg.sender` is not equal to the holder address encoded in `accountId`.
- Otherwise identical to `withdraw`, using the provided `controller` to scope the fund lookup.

This function MUST NOT be subject to the pause mechanism (if any), so that account holders can always recover their tokens even when the Vault is paused.

### Query Functions

A compliant Vault MUST expose the following view functions. All are called by the controller (`msg.sender` determines the controller namespace):

```solidity
function getToken() external view returns (IERC20);
```
Returns the ERC-20 token that this Vault holds custody of.

```solidity
function getBalance(FundId fundId, AccountId accountId) external view returns (uint128);
```
Returns the total token balance of an account (`available + designated`). Returns 0 for `Inactive` funds.

```solidity
function getDesignatedBalance(FundId fundId, AccountId accountId) external view returns (uint128);
```
Returns only the designated portion of the balance. Returns 0 for `Inactive` funds.

```solidity
function getFundStatus(FundId fundId) external view returns (FundStatus);
```
Returns the current state of a fund.

```solidity
function getLockExpiry(FundId fundId) external view returns (Timestamp);
```
Returns the `lockExpiry` timestamp of the fund.

### Invariants

A compliant Vault MUST enforce the following invariant at every state-changing operation. Any operation that would violate it MUST revert.

#### Lock Invariant

```
fund.lockExpiry ≤ fund.lockMaximum
```

The lock expiry can never exceed the maximum established at `lock` time. Checked on `lock` and `extendLock`.

### Errors

| Error | Condition |
|-------|-----------|
| `VaultFundAlreadyLocked` | `lock` called on a fund that is not `Inactive` |
| `VaultFundNotLocked` | A controller operation requiring `Locked` state was called on a fund that is not `Locked` |
| `VaultFundNotUnlocked` | `withdraw` called on a fund that is not `Withdrawing` |
| `VaultInvalidExpiry` | `lock` or `extendLock` called with an `expiry` outside the valid range |
| `VaultInsufficientBalance` | An operation would exceed the available or designated balance |
| `VaultOnlyAccountHolder` | `withdrawByRecipient` called by an address that is not the account holder |

### Pause Mechanism (OPTIONAL)

A Vault implementation MAY support pausing by an owner or governance contract. If pausing is implemented:

- All controller operations (`lock`, `extendLock`, `deposit`, `transfer`, `designate`, `burnDesignated`, `burnAccount`, `freezeFund`, `withdraw`) SHOULD be blocked when paused.
- `withdrawByRecipient` MUST remain callable when paused. Account holders must always be able to recover their tokens.

### Interface

```solidity
// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IERC-XXXX Secure Token Custody Vault
interface IVault {
    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    type FundId is bytes32;

    // AccountId encodes: bytes20(holder) || bytes12(discriminator)
    type AccountId is bytes32;

    enum FundStatus {
        Inactive,
        Locked,
        Frozen,
        Withdrawing
    }

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error VaultFundAlreadyLocked();
    error VaultFundNotLocked();
    error VaultFundNotUnlocked();
    error VaultInvalidExpiry();
    error VaultInsufficientBalance();
    error VaultOnlyAccountHolder();

    // -------------------------------------------------------------------------
    // Account ID helpers
    // -------------------------------------------------------------------------

    function encodeAccountId(address holder, bytes12 discriminator)
        external pure returns (AccountId);

    function decodeAccountId(AccountId id)
        external pure returns (address holder, bytes12 discriminator);

    // -------------------------------------------------------------------------
    // Query functions (msg.sender is the controller)
    // -------------------------------------------------------------------------

    function getToken() external view returns (IERC20);

    function getBalance(FundId fundId, AccountId accountId)
        external view returns (uint128);

    function getDesignatedBalance(FundId fundId, AccountId accountId)
        external view returns (uint128);

    function getFundStatus(FundId fundId) external view returns (FundStatus);

    function getLockExpiry(FundId fundId) external view returns (uint40);

    // -------------------------------------------------------------------------
    // Fund lifecycle (msg.sender is the controller)
    // -------------------------------------------------------------------------

    function lock(FundId fundId, uint40 expiry, uint40 maximum) external;

    function extendLock(FundId fundId, uint40 expiry) external;

    function freezeFund(FundId fundId) external;

    // -------------------------------------------------------------------------
    // Token operations (msg.sender is the controller; fund must be Locked)
    // -------------------------------------------------------------------------

    function deposit(FundId fundId, AccountId accountId, uint128 amount) external;

    function transfer(
        FundId fundId,
        AccountId from,
        AccountId to,
        uint128 amount
    ) external;

    function designate(
        FundId fundId,
        AccountId accountId,
        uint128 amount
    ) external;

    function burnDesignated(
        FundId fundId,
        AccountId accountId,
        uint128 amount
    ) external;

    function burnAccount(FundId fundId, AccountId accountId) external;

    // -------------------------------------------------------------------------
    // Withdrawal (fund must be Withdrawing)
    // -------------------------------------------------------------------------

    /// @notice Called by the controller to withdraw on behalf of an account holder.
    function withdraw(FundId fundId, AccountId accountId) external;

    /// @notice Called directly by the account holder; bypasses the controller.
    ///         MUST remain callable even when the Vault is paused.
    function withdrawByRecipient(
        address controller,
        FundId fundId,
        AccountId accountId
    ) external;
}
```

## Rationale

### Controller-as-caller identity

Using `msg.sender` as the controller address removes the need for explicit access control lists inside the Vault. A controller can only access funds it created. This keeps the interface minimal and avoids a separate registration step.

### `FundId` chosen by the controller

Controllers typically derive `FundId` from a domain object (e.g. a keccak hash of a request ID). This allows deterministic lookup without requiring the Vault to issue IDs, and it means the controller can lock a fund in the same transaction that creates the domain object.

### No `FundId` reuse

Once a `(controller, fundId)` pair has been locked, re-locking the same pair is rejected. This ensures that account state from a previous lifecycle of the fund cannot bleed into a new one.

### Burn address `0x000...dEaD` instead of `address(0)`

Some ERC-20 implementations revert on `transfer` to `address(0)`. Using `0xdEaD` avoids this while making burned tokens visibly auditable on-chain.

### `withdrawByRecipient` not pausable

The ability for account holders to withdraw directly is the ultimate safety guarantee. If the Vault owner or governance is also compromised, pausing the Vault must not be able to trap account holders' funds. A paused Vault that blocks all withdrawals would be indistinguishable from a compromised one.

### No events

This specification does not mandate events in order to keep the interface minimal. Implementations SHOULD emit events for off-chain indexing, but the exact event signatures are left to the implementer to avoid over-constraining the ABI.

## Backwards Compatibility

This is a new interface. No backwards compatibility concerns apply.

## Security Considerations

### Re-entrancy

`deposit` uses `safeTransferFrom`, and `withdraw`/`burnDesignated`/`burnAccount` use `safeTransfer`. Implementations MUST delete or zero out account state before calling `safeTransfer` to prevent re-entrancy from inflating balances. The reference implementation deletes the account record before transferring in `withdraw` and `burnAccount`.

### Integer arithmetic

All balance arithmetic uses `uint128`. Implementations MUST ensure that `balance.available + balance.designated` cannot overflow when computing a withdrawal amount.

### Fund namespace isolation

Because `msg.sender` determines the controller namespace, a Vault that is itself a controller (e.g. a proxy or aggregator) creates a shared namespace for all callers of that contract. Implementers of controller contracts MUST ensure that distinct callers cannot affect each other's funds through the shared controller address.

### Withdrawal completeness

`withdraw` and `withdrawByRecipient` both delete the account record after computing the payout. A second withdrawal call for the same account returns zero. Controllers SHOULD NOT assume that a zero withdrawal means an error; it may indicate a previously withdrawn or empty account.

## Copyright

Copyright and related rights waived via [CC0](../LICENSE.md).
