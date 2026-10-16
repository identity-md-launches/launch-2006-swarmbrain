// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TestBase} from "./utils/TestBase.sol";
import {SwarmbrainToken} from "../src/SwarmbrainToken.sol";

/// @notice Drives the token with random call sequences from a small set of actors, keeping a ghost
///         ledger of what every balance and allowance should be. Every entry point is bounded so
///         that it never reverts on its own; the failure paths are exercised through the `reject*`
///         entry points, which make a call that must fail and check the exact error and that nothing
///         moved. The invariants in `SwarmbrainTokenInvariantTest` compare the token against the ghost
///         ledger after every call.
contract SwarmbrainHandler is TestBase {
    uint256 public constant SUPPLY = 1_000_000_000 * 10 ** 18;

    SwarmbrainToken public immutable token;
    address[] internal actors;

    // ---------------------------------------------------------------------
    // Ghost ledger
    // ---------------------------------------------------------------------

    /// @dev What each actor should hold: the supply for the deployer, then every successful move applied.
    mapping(address account => uint256 balance) public ghost_balance;
    /// @dev What each (owner, spender) allowance should be, with the infinite allowance left alone.
    mapping(address owner => mapping(address spender => uint256 value)) public ghost_allowance;
    /// @dev Total minor units moved by successful transfers, for a sanity check on coverage.
    uint256 public ghost_moved;
    /// @dev Number of calls that were expected to fail, failed, and left state untouched.
    uint256 public ghost_rejected;

    uint256 public calls_transfer;
    uint256 public calls_transferFrom;
    uint256 public calls_approve;
    uint256 public calls_approveInfinite;

    constructor(SwarmbrainToken token_, address deployer, address[] memory actors_) {
        token = token_;
        actors = actors_;
        ghost_balance[deployer] = SUPPLY;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }

    // ---------------------------------------------------------------------
    // Happy paths: bounded so they always succeed
    // ---------------------------------------------------------------------

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));

        vm.prank(from);
        bool ok = token.transfer(to, amount);
        assertTrue(ok, "handler: transfer returned false");

        ghost_balance[from] -= amount;
        ghost_balance[to] += amount;
        ghost_moved += amount;
        calls_transfer++;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        // Keep this one finite so the infinite case stays a deliberate, separate entry point.
        amount = bound(amount, 0, type(uint256).max - 1);

        vm.prank(owner);
        bool ok = token.approve(spender, amount);
        assertTrue(ok, "handler: approve returned false");

        ghost_allowance[owner][spender] = amount;
        calls_approve++;
    }

    function approveInfinite(uint256 ownerSeed, uint256 spenderSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);

        vm.prank(owner);
        bool ok = token.approve(spender, type(uint256).max);
        assertTrue(ok, "handler: approve(max) returned false");

        ghost_allowance[owner][spender] = type(uint256).max;
        calls_approveInfinite++;
    }

    function transferFrom(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address spender = _actor(spenderSeed);
        address from = _actor(fromSeed);
        address to = _actor(toSeed);

        uint256 allowed = token.allowance(from, spender);
        uint256 cap = token.balanceOf(from);
        if (allowed < cap) cap = allowed;
        amount = bound(amount, 0, cap);

        vm.prank(spender);
        bool ok = token.transferFrom(from, to, amount);
        assertTrue(ok, "handler: transferFrom returned false");

        ghost_balance[from] -= amount;
        ghost_balance[to] += amount;
        ghost_moved += amount;
        if (allowed != type(uint256).max) ghost_allowance[from][spender] = allowed - amount;
        calls_transferFrom++;
    }

    // ---------------------------------------------------------------------
    // Failure paths: each call must revert with the exact error and move nothing
    // ---------------------------------------------------------------------

    /// @dev One wei or more above the sender's balance.
    function rejectTransferAboveBalance(uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 balance = token.balanceOf(from);
        excess = bound(excess, 1, type(uint256).max - balance);
        uint256 amount = balance + excess;

        bytes memory expected =
            abi.encodeWithSelector(SwarmbrainToken.ERC20InsufficientBalance.selector, from, balance, amount);
        _mustFail(from, abi.encodeCall(token.transfer, (to, amount)), expected);
    }

    /// @dev Any transfer to the zero address, even of zero, even from the deployer.
    function rejectTransferToZero(uint256 fromSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        amount = bound(amount, 0, token.balanceOf(from));

        bytes memory expected = abi.encodeWithSelector(SwarmbrainToken.ERC20InvalidReceiver.selector, address(0));
        _mustFail(from, abi.encodeCall(token.transfer, (address(0), amount)), expected);
    }

    /// @dev Above a finite allowance: the allowance is checked before the balance, so the error names
    ///      the allowance even when the balance would also be short. With an infinite allowance the
    ///      only thing that can fail is the balance, so that case is checked instead.
    function rejectTransferFromAboveAllowance(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 excess)
        external
    {
        address spender = _actor(spenderSeed);
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 allowed = token.allowance(from, spender);
        bytes memory expected;
        uint256 amount;
        if (allowed == type(uint256).max) {
            uint256 balance = token.balanceOf(from);
            excess = bound(excess, 1, type(uint256).max - balance);
            amount = balance + excess;
            expected = abi.encodeWithSelector(SwarmbrainToken.ERC20InsufficientBalance.selector, from, balance, amount);
        } else {
            excess = bound(excess, 1, type(uint256).max - allowed);
            amount = allowed + excess;
            expected =
                abi.encodeWithSelector(SwarmbrainToken.ERC20InsufficientAllowance.selector, spender, allowed, amount);
        }
        _mustFail(spender, abi.encodeCall(token.transferFrom, (from, to, amount)), expected);
    }

    /// @dev Approving the zero address is refused for every owner and every value.
    function rejectApproveZeroSpender(uint256 ownerSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        bytes memory expected = abi.encodeWithSelector(SwarmbrainToken.ERC20InvalidSpender.selector, address(0));
        _mustFail(owner, abi.encodeCall(token.approve, (address(0), amount)), expected);
    }

    /// @dev No mint, burn, owner, pause or blocklist selector exists for anyone, deployer included.
    function rejectAdminCall(uint256 callerSeed, uint256 selectorSeed, uint256 amount) external {
        address caller = _actor(callerSeed);
        string[14] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "pause()",
            "unpause()",
            "blacklist(address)",
            "freeze(address)",
            "seize(address)",
            "setMinter(address)"
        ];
        string memory signature = signatures[bound(selectorSeed, 0, signatures.length - 1)];
        bytes memory data = abi.encodeWithSignature(signature, caller, amount);

        uint256 supplyBefore = token.totalSupply();
        uint256 balanceBefore = token.balanceOf(caller);
        vm.prank(caller);
        (bool ok,) = address(token).call(data);
        assertFalse(ok, signature);
        assertEq(token.totalSupply(), supplyBefore, "handler: an unknown selector changed the supply");
        assertEq(token.balanceOf(caller), balanceBefore, "handler: an unknown selector changed a balance");
        ghost_rejected++;
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _actor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    /// @dev Makes `data` as `caller`, requires it to fail with exactly `expected`, and checks that the
    ///      supply, the caller's balance and the first actor's balance did not move.
    function _mustFail(address caller, bytes memory data, bytes memory expected) internal {
        uint256 supplyBefore = token.totalSupply();
        uint256 callerBefore = token.balanceOf(caller);
        uint256 deployerBefore = token.balanceOf(actors[0]);

        vm.prank(caller);
        (bool ok, bytes memory ret) = address(token).call(data);
        assertFalse(ok, "handler: a call that had to fail succeeded");
        assertEq(ret, expected, "handler: wrong revert data");

        assertEq(token.totalSupply(), supplyBefore, "handler: a failed call changed the supply");
        assertEq(token.balanceOf(caller), callerBefore, "handler: a failed call changed the caller's balance");
        assertEq(token.balanceOf(actors[0]), deployerBefore, "handler: a failed call changed the deployer's balance");
        ghost_rejected++;
    }
}

/// @notice Invariants over random call sequences against SwarmbrainToken. The handler above is the only
///         target; the invariants compare the token with the handler's ghost ledger after every call.
/// @dev Run counts are set here because foundry.toml is not this task's to change. `fail-on-revert`
///      is on: the handler is written never to revert on its own, so any revert is a real failure.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract SwarmbrainTokenInvariantTest is TestBase {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;

    address internal constant FACTORY = address(0xFAC7);
    address internal constant DISTRIBUTOR = address(0xD157);
    address internal constant POOL = address(0x9001);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA201);

    SwarmbrainToken internal token;
    SwarmbrainHandler internal handler;
    address[] internal actors;

    function setUp() public {
        vm.prank(FACTORY);
        token = new SwarmbrainToken();

        actors.push(FACTORY);
        actors.push(DISTRIBUTOR);
        actors.push(POOL);
        actors.push(ALICE);
        actors.push(BOB);
        actors.push(CAROL);
        handler = new SwarmbrainHandler(token, FACTORY, actors);

        vm.label(address(token), "SWARMBRA");
        vm.label(address(handler), "handler");
        vm.label(FACTORY, "factory");
        vm.label(DISTRIBUTOR, "distributor");
        vm.label(POOL, "pool");
        vm.label(ALICE, "alice");
        vm.label(BOB, "bob");
        vm.label(CAROL, "carol");
    }

    /// @notice Tells Foundry's invariant runner to drive only the handler (the same hook forge-std's
    ///         `targetContract` sets; declared here because the project vendors no forge-std).
    function targetContracts() external view returns (address[] memory targets) {
        targets = new address[](1);
        targets[0] = address(handler);
    }

    // ---------------------------------------------------------------------
    // Invariants
    // ---------------------------------------------------------------------

    /// @dev The supply is fixed at deployment: nothing in any sequence mints or burns.
    function invariant_totalSupplyNeverChanges() public view {
        assertEq(token.totalSupply(), SUPPLY, "totalSupply drifted");
        assertEq(token.TOTAL_SUPPLY(), SUPPLY, "TOTAL_SUPPLY constant drifted");
    }

    /// @dev Conservation: what the actors hold between them is exactly the supply, so no transfer
    ///      created or destroyed value and nothing leaked to an address outside the set.
    function invariant_sumOfBalancesEqualsSupply() public view {
        uint256 sum;
        for (uint256 i = 0; i < actors.length; i++) {
            sum += token.balanceOf(actors[i]);
        }
        assertEq(sum, token.totalSupply(), "balances do not sum to the supply");
    }

    /// @dev Every balance equals the ghost ledger's: each successful transfer moved exactly its amount
    ///      from the sender to the receiver and nothing else.
    function invariant_balancesMatchGhostLedger() public view {
        for (uint256 i = 0; i < actors.length; i++) {
            assertEq(token.balanceOf(actors[i]), handler.ghost_balance(actors[i]), "balance differs from ledger");
        }
    }

    /// @dev Every allowance equals the ghost ledger's: approve sets it exactly, transferFrom spends
    ///      exactly the amount, and the infinite allowance is never decremented.
    function invariant_allowancesMatchGhostLedger() public view {
        for (uint256 i = 0; i < actors.length; i++) {
            for (uint256 j = 0; j < actors.length; j++) {
                assertEq(
                    token.allowance(actors[i], actors[j]),
                    handler.ghost_allowance(actors[i], actors[j]),
                    "allowance differs from ledger"
                );
            }
        }
    }

    /// @dev Nobody holds more than the supply, and no actor can ever have been overdrawn.
    function invariant_noBalanceExceedsSupply() public view {
        for (uint256 i = 0; i < actors.length; i++) {
            assertLe(token.balanceOf(actors[i]), SUPPLY, "a balance exceeds the supply");
        }
    }

    /// @dev Nothing ever lands on the zero address, the token itself, the handler or this test.
    function invariant_strangersHoldNothing() public view {
        assertEq(token.balanceOf(address(0)), 0, "the zero address holds tokens");
        assertEq(token.balanceOf(address(token)), 0, "the token holds tokens");
        assertEq(token.balanceOf(address(handler)), 0, "the handler holds tokens");
        assertEq(token.balanceOf(address(this)), 0, "the test holds tokens");
    }

    /// @dev The ghost ledger itself is consistent: it sums to the supply too, so a ledger bug cannot
    ///      hide a token bug by drifting in step with it.
    function invariant_ghostLedgerSumsToSupply() public view {
        uint256 sum;
        for (uint256 i = 0; i < actors.length; i++) {
            sum += handler.ghost_balance(actors[i]);
        }
        assertEq(sum, SUPPLY, "ghost ledger does not sum to the supply");
    }

    /// @dev Metadata is immutable across any sequence of calls.
    function invariant_metadataIsConstant() public view {
        assertEq(token.name(), "Swarmbrain", "name changed");
        assertEq(token.symbol(), "SWARMBRA", "symbol changed");
        assertEq(uint256(token.decimals()), 18, "decimals changed");
    }
}
