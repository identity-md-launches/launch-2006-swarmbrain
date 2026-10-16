// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Swarmbrain (SWARMBRA)
/// @notice Fixed-supply ERC-20 for Swarmbrain: a brain made of hundreds of AI agents on strangers'
///         computers, trading real money, in public. X handle: swarmbrain. Website: swarmbrain.fun.
/// @dev Design, in one paragraph: the whole supply (1,000,000,000 tokens, 18 decimals) is minted
///      exactly once, in the constructor, to the deployer (`msg.sender`, which at launch is the
///      ProjectFactory). There is no owner, no minter, no pause, no blocklist, no fee and no hook
///      on transfer: every transfer moves exactly the amount asked, for every sender, forever.
///      The supply can never grow because nothing but the constructor calls `_mint`, and the
///      contract has no `burn`, so `totalSupply()` is constant for the life of the contract.
///      Behaviour follows ERC-20 with OpenZeppelin v5 semantics and ERC-6093 custom errors,
///      implemented here directly so the project has no external dependency.
contract SwarmbrainToken {
    // ---------------------------------------------------------------------
    // Metadata and supply
    // ---------------------------------------------------------------------

    /// @notice ERC-20 name.
    string public constant name = "Swarmbrain";

    /// @notice ERC-20 symbol.
    string public constant symbol = "SWARMBRA";

    /// @notice ERC-20 decimals.
    uint8 public constant decimals = 18;

    /// @notice The whole supply in minor units: 1,000,000,000 * 10 ** 18. Minted once, never again.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    // ---------------------------------------------------------------------
    // Events (ERC-20)
    // ---------------------------------------------------------------------

    /// @notice Emitted when `value` tokens move from `from` to `to`. Minting emits from the zero address.
    event Transfer(address indexed from, address indexed to, uint256 value);

    /// @notice Emitted when `owner` sets `spender`'s allowance to `value`.
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // ---------------------------------------------------------------------
    // Errors (ERC-6093)
    // ---------------------------------------------------------------------

    /// @notice `sender` holds `balance` but the transfer needs `needed`.
    error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed);

    /// @notice A transfer from an invalid sender (the zero address).
    error ERC20InvalidSender(address sender);

    /// @notice A transfer to an invalid receiver (the zero address).
    error ERC20InvalidReceiver(address receiver);

    /// @notice `spender` may spend `allowance` but the transfer needs `needed`.
    error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed);

    /// @notice An approval from an invalid approver (the zero address).
    error ERC20InvalidApprover(address approver);

    /// @notice An approval of an invalid spender (the zero address).
    error ERC20InvalidSpender(address spender);

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    uint256 private _totalSupply;
    mapping(address account => uint256 balance) private _balances;
    mapping(address owner => mapping(address spender => uint256 value)) private _allowances;

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    /// @notice Mints the whole supply to the deployer. Takes no arguments and calls no other contract,
    ///         so it deploys on an empty chain and has nothing an operator can misconfigure.
    constructor() {
        _mint(msg.sender, TOTAL_SUPPLY);
    }

    // ---------------------------------------------------------------------
    // ERC-20 views
    // ---------------------------------------------------------------------

    /// @notice Tokens in existence. Equal to `TOTAL_SUPPLY` forever: nothing mints or burns after deployment.
    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    /// @notice Tokens held by `account`.
    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    /// @notice Tokens `spender` may still move on behalf of `owner`.
    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowances[owner][spender];
    }

    // ---------------------------------------------------------------------
    // ERC-20 actions
    // ---------------------------------------------------------------------

    /// @notice Moves `value` tokens from the caller to `to`.
    /// @dev Reverts with `ERC20InvalidReceiver` for the zero address and `ERC20InsufficientBalance`
    ///      when the caller holds less than `value`. Always returns true.
    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    /// @notice Sets `spender`'s allowance over the caller's tokens to `value`, replacing any earlier value.
    /// @dev Reverts with `ERC20InvalidSpender` for the zero address. Always returns true.
    function approve(address spender, uint256 value) external returns (bool) {
        _approve(msg.sender, spender, value);
        return true;
    }

    /// @notice Moves `value` tokens from `from` to `to` using the caller's allowance.
    /// @dev Reverts with `ERC20InsufficientAllowance` when the allowance is short. An allowance of
    ///      `type(uint256).max` is treated as infinite and is not decremented. Always returns true.
    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        _spendAllowance(from, msg.sender, value);
        _transfer(from, to, value);
        return true;
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    function _transfer(address from, address to, uint256 value) private {
        if (from == address(0)) revert ERC20InvalidSender(address(0));
        if (to == address(0)) revert ERC20InvalidReceiver(address(0));
        uint256 fromBalance = _balances[from];
        if (fromBalance < value) revert ERC20InsufficientBalance(from, fromBalance, value);
        unchecked {
            // Cannot underflow: fromBalance >= value was just checked.
            _balances[from] = fromBalance - value;
            // Cannot overflow: the sum of all balances is bounded by _totalSupply, which fits in uint256.
            _balances[to] += value;
        }
        emit Transfer(from, to, value);
    }

    /// @dev Only the constructor calls this. There is no external path to it, so the supply is fixed.
    function _mint(address account, uint256 value) private {
        if (account == address(0)) revert ERC20InvalidReceiver(address(0));
        _totalSupply += value;
        unchecked {
            // Cannot overflow: a single balance never exceeds _totalSupply.
            _balances[account] += value;
        }
        emit Transfer(address(0), account, value);
    }

    function _approve(address owner, address spender, uint256 value) private {
        if (owner == address(0)) revert ERC20InvalidApprover(address(0));
        if (spender == address(0)) revert ERC20InvalidSpender(address(0));
        _allowances[owner][spender] = value;
        emit Approval(owner, spender, value);
    }

    function _spendAllowance(address owner, address spender, uint256 value) private {
        uint256 currentAllowance = _allowances[owner][spender];
        if (currentAllowance == type(uint256).max) return;
        if (currentAllowance < value) revert ERC20InsufficientAllowance(spender, currentAllowance, value);
        unchecked {
            // Cannot underflow: currentAllowance >= value was just checked. No Approval event is
            // emitted here, matching OpenZeppelin v5: the allowance change is implied by Transfer.
            _allowances[owner][spender] = currentAllowance - value;
        }
    }
}
