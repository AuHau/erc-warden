# ERC Warden: A Secure Token Custody Standard

## Overview

The Warden is a smart contract pattern that separates ERC20 token custody from business logic,
reducing the attack surface of contracts that manage funds. Rather than holding tokens directly,
a business-logic contract (called a **controller**) delegates all token custody to an external
Warden contract. The Warden enforces strict rules about when and how tokens can move, adding
time-based and designation-based protections that limit the damage an attacker can do even
after compromising the controller.

---

## Motivation

Most DeFi contracts hold their own tokens. When a bug or exploit is found in the business
logic, an attacker can often drain funds in a single transaction. The Warden pattern introduces
**defence in depth**: even if a controller is fully compromised, the Warden's invariants ensure
that:

- Tokens cannot be redirected immediately - they are sealed in place once a time-lock expires.
- Collateral tokens can be permanently committed (designated) to their rightful owner,
  making redirection impossible.
- Account holders can always withdraw directly, bypassing a compromised controller entirely.
- Burning tokens is always available as a last resort to destroy value rather than let an
  attacker capture it.

---

## Concept

### Hierarchy

```
Warden
 └── Controller (a smart contract address)
      └── Fund (identified by a bytes32 FundId chosen by the controller)
           └── Account (identified by AccountId = holder address ++ 12-byte discriminator)
                ├── available balance
                └── designated balance
```

Each controller (i.e. each deployed business-logic contract) has its own isolated namespace
of funds inside the shared Warden. Controllers cannot access each other's funds.

Each fund is a collection of accounts that share a single lifecycle (the time-lock). Funds
are created by the controller choosing a unique `FundId`

Each account belongs to a fund and tracks:
- **available balance** - tokens that the controller can still redistribute between accounts
- **designated balance** - tokens irreversibly committed to the account holder; cannot be
  transferred away, only burned or withdrawn

### Account Identity

An `AccountId` encodes both the **holder address** (20 bytes) and a **discriminator** (12 bytes).
The discriminator allows a single address to hold multiple separate accounts within the same fund.
The holder address embedded in the ID is used to route withdrawals; it does not need to be the
`msg.sender` of any transaction.

---

## Lifecycle

### Fund States

```
Inactive ──lock()──► Locked ──time passes──► Withdrawing
                        │
                    sealFund()
                        │
                        ▼
                      Sealed ──time passes──► Withdrawing
```

| State       | Allowed operations |
|-------------|-------------------|
| Inactive    | `lock()` |
| Locked      | `deposit`, `transfer`, `designate`, `burnDesignated`, `burnAccount`, `extendLock`, `sealFund` |
| Sealed      | nothing (balances fixed) |
| Withdrawing | `withdraw`, `withdrawByRecipient` |

The controller determines when and for how long a fund is locked, subject to two constraints
set at lock time:

- `lockExpiry` - when the lock expires naturally
- `lockMaximum` - the furthest the expiry can ever be extended

The `lockMaximum` is fixed at lock creation time and cannot be changed. This means the Warden
can enforce the **account solvency invariant** at the time a flow is set up: the available
balance must be sufficient to pay the outgoing flow all the way to `lockMaximum`, regardless
of any future `extendLock` calls.

---

## Core Operations

### Locking (`lock`, `extendLock`)

The controller calls `lock(fundId, expiry, maximum)` once to activate a fund. The `expiry`
is when tokens become withdrawable; `maximum` is the ceiling on any later extension.
If supporting later lock extensions is not needed there is also `lock(fundId, expiry)` available
for use.

`extendLock(fundId, newExpiry)` pushes the expiry forward (within `maximum`).

### Depositing (`deposit`)

The controller calls `deposit(fundId, accountId, amount)` to move ERC20 tokens from the
controller (or another approved address) into the Warden, crediting an account's available
balance.

### Transferring (`transfer`)

`transfer(fundId, from, to, amount)` moves available tokens between two accounts within the
same fund. Only the controller can call this while the fund is locked. Crucially, it can only
move *available* (not designated) tokens.

### Designation (`designate`)

`designate(fundId, accountId, amount)` moves tokens from an account's available balance into
its designated balance. Designated tokens:
- **cannot be transferred** to any other account
- **can be burned** by the controller
- **will be paid out** to the account holder on withdrawal

This is used for collateral: once committed as designated, collateral cannot be stolen by a
compromised controller even if the controller tries to transfer it away.

### Token Flows (`flow`)

`flow(fundId, from, to, rate)` establishes a **continuous token stream** at `rate`
tokens-per-second from one account to another. Flows are tracked lazily: no tokens move at
every block. Instead, when any state-changing operation is applied to an account, the
accumulated flow since the last update is computed and applied.

Tokens flowing *into* an account become **designated** immediately on arrival - they cannot
be redirected away.

The solvency invariant is enforced when a flow is set up: the sending account's available
balance must cover the total outflow from the current time to `lockMaximum`.

Flows are useful for streaming payments (e.g. a client paying a storage provider
per-second for the duration of a deal).

### Burning (`burnDesignated`, `burnAccount`)

`burnDesignated(fundId, accountId, amount)` destroys designated tokens (sends to
`0x000...dead`). This implements penalty/slashing: the tokens are destroyed rather than
redistributed.

`burnAccount(fundId, accountId)` destroys an entire account's balance, but only when the
account has no active flows. Used when a participant is forcibly removed.

### Sealing (`sealFund`)

`sealFund(fundId)` seals account balances - no further transfers, designations, deposits, or
burns are permitted until the lock expires and withdrawals begin. Used when the controller
needs to commit to the current allocation and prevent any further changes.

### Withdrawal (`withdraw`, `withdrawByRecipient`)

After the fund unlocks (state transitions to `Withdrawing`), tokens can be sent to their
holders. The total payout for an account is `available + designated`.

`withdraw(fundId, accountId)` can be called by the controller on behalf of an account holder.

`withdrawByRecipient(controller, fundId, accountId)` can be called **directly by the account
holder**, bypassing the controller entirely. This is a critical safety property: a compromised
or griefing controller cannot block withdrawals.

---

## Invariants

The Warden maintains the following invariant at all times:

### Lock Invariant
```
fund.lockExpiry <= fund.lockMaximum
```
The expiry can never exceed the maximum set at lock time.

---

## Security Properties

| Threat | Mitigation |
|--------|-----------|
| Controller exploited - attacker tries to redirect funds | Funds are locked; attacker can only reassign during the lock window. Once the lock expires, tokens are fixed in place. |
| Controller redirects collateral to attacker | Collateral is designated at deposit time; designated tokens cannot be transferred. |
| Compromised controller maliciously upgrades to block withdrawals | Account holders can call `withdrawByRecipient` directly, bypassing the controller. |
| Partial compromise - attacker controls some state | `sealFund` lets the controller commit to the current allocation, preventing any further redistribution. |

---

## Example: Storage Marketplace Usage

The Warden was designed for a decentralised storage marketplace (Archivist/Codex). The
Marketplace contract acts as the controller. For each storage request:

1. A `FundId` is derived from the request ID.
2. The fund is locked for the expiry window; the maximum is the full request duration.
3. The client deposits payment tokens into a client account.
4. A self-directed flow (`client → client`) ensures that unspent payment slowly designates
   itself back to the client (so it is returned if fewer than expected hosts fill slots).
5. When a host fills a slot:
   - The host deposits collateral; most of it is immediately **designated** to the host.
   - A **flow** is set from the client account to the host account at the per-second price.
6. If a host misses proofs (slashing):
   - A portion of their designated collateral is burned.
   - A validator reward is transferred to a validator account and immediately designated.
7. If a host is forcibly removed:
   - Their incoming flow is reversed back to the client.
   - Remaining balance is burned.
8. When the request ends:
   - The lock expires; the fund enters the Withdrawing state.
   - Hosts call `freeSlot` → `withdraw` to receive accumulated payment + remaining collateral.
   - The client calls `withdrawFunds` to receive any unspent payment.

---

## Interface (Proposed)

```solidity
interface IWarden {
    // Types
    type FundId is bytes32;
    type AccountId is bytes32;  // 20-byte holder || 12-byte discriminator
    type TokensPerSecond is uint96;

    enum FundStatus { Inactive, Locked, Sealed, Withdrawing }

    // Account ID helpers
    function encodeAccountId(address holder, bytes12 discriminator) external pure returns (AccountId);
    function decodeAccountId(AccountId id) external pure returns (address holder, bytes12 discriminator);

    // Queries (caller is the controller)
    function getBalance(FundId fundId, AccountId accountId) external view returns (uint128);
    function getDesignatedBalance(FundId fundId, AccountId accountId) external view returns (uint128);
    function getFundStatus(FundId fundId) external view returns (FundStatus);
    function getLockExpiry(FundId fundId) external view returns (uint40 timestamp);

    // Fund lifecycle (caller is the controller)
    function lock(FundId fundId, uint40 expiry, uint40 maximum) external;
    function extendLock(FundId fundId, uint40 expiry) external;
    function sealFund(FundId fundId) external;

    // Token operations (caller is the controller, fund must be Locked)
    function deposit(FundId fundId, AccountId accountId, uint128 amount) external;
    function transfer(FundId fundId, AccountId from, AccountId to, uint128 amount) external;
    function designate(FundId fundId, AccountId accountId, uint128 amount) external;
    function flow(FundId fundId, AccountId from, AccountId to, TokensPerSecond rate) external;
    function burnDesignated(FundId fundId, AccountId accountId, uint128 amount) external;
    function burnAccount(FundId fundId, AccountId accountId) external;

    // Withdrawal (fund must be Withdrawing)
    function withdraw(FundId fundId, AccountId accountId) external;   // called by controller
    function withdrawByRecipient(address controller, FundId fundId, AccountId accountId) external; // called by account holder
}
```

---

## Comparison with Existing ERCs

No existing ERC covers this combination of features. The table below maps each key property
against the closest existing standards.

| Feature | This ERC | ERC-4626 | ERC-6229 | ERC-7444 | ERC-1620 |
|---------|----------|----------|----------|----------|----------|
| Controller/custody separation | ✅ | ❌ | ❌ | ❌ | Partial |
| Time-locked funds | ✅ | ❌ | ✅ (schedule/settle) | ✅ (maturity query only) | ❌ |
| Multi-account fund isolation | ✅ | ❌ | ❌ | ❌ | ❌ |
| Token designation (irreversible commitment) | ✅ | ❌ | ❌ | ❌ | ❌ |
| Token streaming with solvency invariant | ✅ | ❌ | ❌ | ❌ | ✅ (no invariant) |
| Direct withdrawal by recipient | ✅ | ✅ (shares) | ❌ | ❌ | ✅ |
| Freeze / emergency halt | ✅ | ❌ | ❌ | ❌ | ❌ |
| Lock extension with bounded maximum | ✅ | ❌ | ❌ | ❌ | ❌ |

### ERC-4626 - Tokenized Vault Standard (Final)
ERC-4626 standardises **yield-bearing vaults** where depositors receive share tokens
representing their claim. It is focused on composability between yield strategies. The Warden
described here has a different goal: **security isolation** rather than yield. There are no
share tokens; accounts are tracked internally by the controller's domain objects. The two
standards are complementary and could coexist.

### ERC-6229 - Tokenized Vaults with Lock-in Period (Draft)
ERC-6229 extends ERC-4626 by adding a lock/unlock cycle where deposits and redemptions are
queued during the locked phase and settled at unlock. It is oriented around **yield strategy
execution** (e.g. a vault that needs to deploy capital for a period). It has no notion of
controller/custody separation, no designation semantics, no streaming, and no multi-account
fund management. Its lock mechanism serves a different purpose - preventing front-running of
a strategy - rather than protecting funds from a compromised controller.

### ERC-7444 - Time Locks Maturity (Draft)
ERC-7444 defines a single function `getMaturity(bytes32 id)` that returns the Unix timestamp
at which a locked asset becomes accessible. It is a **query interface** only, not a custody
or fund-management interface. It does not specify how locking is enforced, how funds flow, or
how accounts are isolated.

### ERC-1620 - Money Streaming (Draft)
ERC-1620 proposes a standard for continuous token streams between two parties (sender →
recipient) tracked by block number. Streams are 1-to-1, there is no multi-account fund
grouping, no designation, no lock/unlock lifecycle, and no solvency invariant. The Warden's
streaming primitive is similar in spirit but is integrated with the fund lifecycle: streams
are bounded by the lock maximum, and tokens flowing into an account are immediately
designated, preventing re-redirection.

### Summary

The Warden standard introduces a novel combination: a **controller-scoped custody layer** that
groups multiple accounts into time-locked funds and enforces designation and streaming
semantics to protect funds throughout a multi-party deal lifecycle. No existing ERC covers
this design space.
