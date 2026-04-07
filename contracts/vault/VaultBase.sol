// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./Accounts.sol";
import "./Funds.sol";

/// Unique identifier for a fund, chosen by the controller
type FundId is bytes32;

/// Records account balances. Accounts are separated into funds.
/// Funds are kept separate between controllers.
///
/// A fund can only be manipulated by a controller when it is locked. Tokens can
/// only be withdrawn when a fund is unlocked.
///
/// The vault maintains the lock invariant to ensure its integrity:
///
/// (∀ controller ∈ Controller, fundId ∈ FundId:
///   fund.lockExpiry <= fund.lockMaximum
///   where fund = _funds[controller][fundId])
///
abstract contract VaultBase {
  using SafeERC20 for IERC20;
  using Funds for Fund;

  IERC20 internal immutable _token;

  /// Represents a smart contract that can redistribute and burn tokens in funds
  type Controller is address;

  /// Each controller has its own set of funds
  mapping(Controller => mapping(FundId => Fund)) private _funds;
  /// Each account holder has its own set of accounts in a fund
  mapping(Controller => mapping(FundId => mapping(AccountId => Account)))
    private _accounts;

  constructor(IERC20 token) {
    _token = token;
  }

  function _getFundStatus(
    Controller controller,
    FundId fundId
  ) internal view returns (FundStatus) {
    return _funds[controller][fundId].status();
  }

  function _getLockExpiry(
    Controller controller,
    FundId fundId
  ) internal view returns (Timestamp) {
    return _funds[controller][fundId].lockExpiry;
  }

  function _getBalance(
    Controller controller,
    FundId fundId,
    AccountId accountId
  ) internal view returns (Balance memory) {
    if (_funds[controller][fundId].status() == FundStatus.Inactive) {
      return Balance({available: 0, designated: 0});
    }
    return _accounts[controller][fundId][accountId].balance;
  }

  function _lock(
    Controller controller,
    FundId fundId,
    Timestamp expiry,
    Timestamp maximum
  ) internal {
    Fund memory fund = _funds[controller][fundId];
    require(fund.status() == FundStatus.Inactive, VaultFundAlreadyLocked());
    fund.lockExpiry = expiry;
    fund.lockMaximum = maximum;
    _checkLockInvariant(fund);
    _funds[controller][fundId] = fund;
  }

  function _extendLock(
    Controller controller,
    FundId fundId,
    Timestamp expiry
  ) internal {
    Fund memory fund = _funds[controller][fundId];
    require(fund.status() == FundStatus.Locked, VaultFundNotLocked());
    require(fund.lockExpiry <= expiry, VaultInvalidExpiry());
    fund.lockExpiry = expiry;
    _checkLockInvariant(fund);
    _funds[controller][fundId] = fund;
  }

  function _deposit(
    Controller controller,
    FundId fundId,
    AccountId accountId,
    uint128 amount
  ) internal {
    Fund storage fund = _funds[controller][fundId];
    require(fund.status() == FundStatus.Locked, VaultFundNotLocked());

    Account storage account = _accounts[controller][fundId][accountId];

    account.balance.available += amount;

    _token.safeTransferFrom(
      Controller.unwrap(controller),
      address(this),
      amount
    );
  }

  function _designate(
    Controller controller,
    FundId fundId,
    AccountId accountId,
    uint128 amount
  ) internal {
    Fund memory fund = _funds[controller][fundId];
    require(fund.status() == FundStatus.Locked, VaultFundNotLocked());

    Account memory account = _accounts[controller][fundId][accountId];
    require(amount <= account.balance.available, VaultInsufficientBalance());

    account.balance.available -= amount;
    account.balance.designated += amount;

    _accounts[controller][fundId][accountId] = account;
  }

  function _transfer(
    Controller controller,
    FundId fundId,
    AccountId from,
    AccountId to,
    uint128 amount
  ) internal {
    Fund memory fund = _funds[controller][fundId];
    require(fund.status() == FundStatus.Locked, VaultFundNotLocked());

    Account memory sender = _accounts[controller][fundId][from];
    require(amount <= sender.balance.available, VaultInsufficientBalance());

    sender.balance.available -= amount;

    _accounts[controller][fundId][from] = sender;

    _accounts[controller][fundId][to].balance.available += amount;
  }

  function _burnDesignated(
    Controller controller,
    FundId fundId,
    AccountId accountId,
    uint128 amount
  ) internal {
    Fund storage fund = _funds[controller][fundId];
    require(fund.status() == FundStatus.Locked, VaultFundNotLocked());

    Account storage account = _accounts[controller][fundId][accountId];
    require(account.balance.designated >= amount, VaultInsufficientBalance());

    account.balance.designated -= amount;

    _token.safeTransfer(address(0xdead), amount);
  }

  function _burnAccount(
    Controller controller,
    FundId fundId,
    AccountId accountId
  ) internal {
    require(
      _funds[controller][fundId].status() == FundStatus.Locked,
      VaultFundNotLocked()
    );

    Account memory account = _accounts[controller][fundId][accountId];
    uint128 amount = account.balance.available + account.balance.designated;

    delete _accounts[controller][fundId][accountId];

    _token.safeTransfer(address(0xdead), amount);
  }

  function _freezeFund(Controller controller, FundId fundId) internal {
    Fund storage fund = _funds[controller][fundId];
    require(fund.status() == FundStatus.Locked, VaultFundNotLocked());

    fund.frozenAt = Timestamps.currentTime();
  }

  function _withdraw(
    Controller controller,
    FundId fundId,
    AccountId accountId
  ) internal {
    require(
      _funds[controller][fundId].status() == FundStatus.Withdrawing,
      VaultFundNotUnlocked()
    );

    Account memory account = _accounts[controller][fundId][accountId];
    uint128 amount = account.balance.available + account.balance.designated;

    delete _accounts[controller][fundId][accountId];

    (address owner, ) = Accounts.decodeId(accountId);
    _token.safeTransfer(owner, amount);
  }

  function _checkLockInvariant(Fund memory fund) private pure {
    require(fund.lockExpiry <= fund.lockMaximum, VaultInvalidExpiry());
  }

  error VaultInsufficientBalance();
  error VaultInvalidExpiry();
  error VaultFundNotLocked();
  error VaultFundNotUnlocked();
  error VaultFundAlreadyLocked();
}
