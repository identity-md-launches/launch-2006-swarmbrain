// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TestBase} from "./utils/TestBase.sol";
import {SwarmbrainToken} from "../src/SwarmbrainToken.sol";

/// @notice Unit, failure and fuzz tests for SwarmbrainToken. No test reads the environment and none
///         depends on which address runs it: the token is deployed by a pranked `FACTORY` in `setUp`.
contract SwarmbrainTokenTest is TestBase {
    // Mirrors of the token's events, so `expectEmit` can compare against them.
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;

    /// @dev Stands in for the ProjectFactory: the deployer, which receives the whole supply.
    address internal constant FACTORY = address(0xFAC7);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA201);
    address internal constant DISTRIBUTOR = address(0xD157);
    address internal constant POOL = address(0x9001);
    address internal constant ATTACKER = address(0xBEEF);

    SwarmbrainToken internal token;

    function setUp() public {
        vm.prank(FACTORY);
        token = new SwarmbrainToken();
        vm.label(address(token), "SWARMBRA");
        vm.label(FACTORY, "factory");
        vm.label(ALICE, "alice");
        vm.label(BOB, "bob");
    }

    // ---------------------------------------------------------------------
    // Metadata and supply
    // ---------------------------------------------------------------------

    function test_metadata() public view {
        assertEq(token.name(), "Swarmbrain", "name");
        assertEq(token.symbol(), "SWARMBRA", "symbol");
        assertEq(token.decimals(), 18, "decimals");
    }

    function test_constructorMintsWholeSupplyToDeployerOnce() public view {
        assertEq(token.TOTAL_SUPPLY(), SUPPLY, "TOTAL_SUPPLY constant");
        assertEq(token.totalSupply(), SUPPLY, "totalSupply");
        assertEq(token.balanceOf(FACTORY), SUPPLY, "deployer holds the whole supply");
        assertEq(token.balanceOf(address(this)), 0, "the test contract holds nothing");
        assertEq(token.balanceOf(address(token)), 0, "the token holds nothing");
    }

    function test_supplyIsOneBillionWithEighteenDecimals() public view {
        assertEq(token.totalSupply() / (10 ** uint256(token.decimals())), 1_000_000_000, "whole tokens");
        assertEq(token.totalSupply() % (10 ** uint256(token.decimals())), 0, "no fractional remainder");
    }

    function test_freshDeploymentAlwaysMintsToItsOwnDeployer() public {
        vm.prank(ALICE);
        SwarmbrainToken other = new SwarmbrainToken();
        assertEq(other.balanceOf(ALICE), SUPPLY, "alice deployed, alice holds the supply");
        assertEq(other.balanceOf(FACTORY), 0, "the factory holds none of a token it did not deploy");
        assertEq(other.totalSupply(), SUPPLY, "same fixed supply");
    }

    // ---------------------------------------------------------------------
    // transfer: success
    // ---------------------------------------------------------------------

    function test_transferMovesBalanceAndEmits() public {
        uint256 amount = 1_000 * 10 ** 18;
        vm.expectEmit(true, true, false, true);
        emit Transfer(FACTORY, ALICE, amount);
        vm.prank(FACTORY);
        bool ok = token.transfer(ALICE, amount);
        assertTrue(ok, "transfer returns true");
        assertEq(token.balanceOf(ALICE), amount, "alice received exactly the amount");
        assertEq(token.balanceOf(FACTORY), SUPPLY - amount, "factory paid exactly the amount");
        assertEq(token.totalSupply(), SUPPLY, "supply unchanged");
    }

    function test_transferWholeBalance() public {
        vm.prank(FACTORY);
        token.transfer(ALICE, SUPPLY);
        assertEq(token.balanceOf(ALICE), SUPPLY, "alice holds everything");
        assertEq(token.balanceOf(FACTORY), 0, "factory holds nothing");
    }

    function test_transferZeroAmountSucceeds() public {
        vm.prank(ALICE);
        bool ok = token.transfer(BOB, 0);
        assertTrue(ok, "zero transfer returns true");
        assertEq(token.balanceOf(BOB), 0, "bob still holds nothing");
    }

    function test_transferToSelfKeepsBalance() public {
        vm.prank(FACTORY);
        token.transfer(FACTORY, SUPPLY);
        assertEq(token.balanceOf(FACTORY), SUPPLY, "self transfer keeps the balance");
    }

    function test_anyHolderCanTransferOnward() public {
        vm.prank(FACTORY);
        token.transfer(ALICE, 500);
        vm.prank(ALICE);
        token.transfer(BOB, 200);
        vm.prank(BOB);
        token.transfer(CAROL, 50);
        assertEq(token.balanceOf(ALICE), 300, "alice");
        assertEq(token.balanceOf(BOB), 150, "bob");
        assertEq(token.balanceOf(CAROL), 50, "carol");
        assertEq(token.balanceOf(FACTORY), SUPPLY - 500, "factory");
    }

    // ---------------------------------------------------------------------
    // transfer: failure
    // ---------------------------------------------------------------------

    function test_transferRevertsWhenBalanceInsufficient() public {
        vm.expectRevert(abi.encodeWithSelector(SwarmbrainToken.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transfer(BOB, 1);
    }

    function test_transferRevertsOneWeiAboveBalance() public {
        vm.expectRevert(
            abi.encodeWithSelector(SwarmbrainToken.ERC20InsufficientBalance.selector, FACTORY, SUPPLY, SUPPLY + 1)
        );
        vm.prank(FACTORY);
        token.transfer(ALICE, SUPPLY + 1);
        assertEq(token.balanceOf(FACTORY), SUPPLY, "nothing moved");
    }

    function test_transferRevertsToZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(SwarmbrainToken.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(FACTORY);
        token.transfer(address(0), 1);
        assertEq(token.totalSupply(), SUPPLY, "nothing burned");
    }

    // ---------------------------------------------------------------------
    // approve
    // ---------------------------------------------------------------------

    function test_approveSetsAllowanceAndEmits() public {
        vm.expectEmit(true, true, false, true);
        emit Approval(FACTORY, ALICE, 123);
        vm.prank(FACTORY);
        bool ok = token.approve(ALICE, 123);
        assertTrue(ok, "approve returns true");
        assertEq(token.allowance(FACTORY, ALICE), 123, "allowance set");
        assertEq(token.allowance(ALICE, FACTORY), 0, "the reverse allowance is untouched");
    }

    function test_approveOverwritesEarlierValue() public {
        vm.startPrank(FACTORY);
        token.approve(ALICE, 100);
        token.approve(ALICE, 7);
        vm.stopPrank();
        assertEq(token.allowance(FACTORY, ALICE), 7, "latest approve wins");
        vm.prank(FACTORY);
        token.approve(ALICE, 0);
        assertEq(token.allowance(FACTORY, ALICE), 0, "approve to zero clears it");
    }

    function test_approveRevertsForZeroSpender() public {
        vm.expectRevert(abi.encodeWithSelector(SwarmbrainToken.ERC20InvalidSpender.selector, address(0)));
        vm.prank(FACTORY);
        token.approve(address(0), 1);
    }

    // ---------------------------------------------------------------------
    // transferFrom: success
    // ---------------------------------------------------------------------

    function test_transferFromSpendsAllowanceAndEmits() public {
        vm.prank(FACTORY);
        token.approve(ALICE, 1_000);

        vm.expectEmit(true, true, false, true);
        emit Transfer(FACTORY, BOB, 400);
        vm.prank(ALICE);
        bool ok = token.transferFrom(FACTORY, BOB, 400);
        assertTrue(ok, "transferFrom returns true");
        assertEq(token.balanceOf(BOB), 400, "bob received");
        assertEq(token.balanceOf(FACTORY), SUPPLY - 400, "factory paid");
        assertEq(token.balanceOf(ALICE), 0, "the spender received nothing itself");
        assertEq(token.allowance(FACTORY, ALICE), 600, "allowance decremented by exactly the amount");
    }

    function test_transferFromCanSpendExactAllowance() public {
        vm.prank(FACTORY);
        token.approve(ALICE, 1_000);
        vm.prank(ALICE);
        token.transferFrom(FACTORY, BOB, 1_000);
        assertEq(token.allowance(FACTORY, ALICE), 0, "allowance fully spent");
        assertEq(token.balanceOf(BOB), 1_000, "bob received");
    }

    function test_transferFromInfiniteAllowanceIsNotDecremented() public {
        vm.prank(FACTORY);
        token.approve(ALICE, type(uint256).max);
        vm.prank(ALICE);
        token.transferFrom(FACTORY, BOB, 5_000);
        assertEq(token.allowance(FACTORY, ALICE), type(uint256).max, "infinite allowance stays infinite");
        assertEq(token.balanceOf(BOB), 5_000, "bob received");
    }

    // ---------------------------------------------------------------------
    // transferFrom: failure
    // ---------------------------------------------------------------------

    function test_transferFromRevertsWithoutApproval() public {
        vm.expectRevert(abi.encodeWithSelector(SwarmbrainToken.ERC20InsufficientAllowance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transferFrom(FACTORY, ALICE, 1);
        assertEq(token.balanceOf(FACTORY), SUPPLY, "nothing moved");
    }

    function test_transferFromRevertsWhenAllowanceInsufficient() public {
        vm.prank(FACTORY);
        token.approve(ALICE, 99);
        vm.expectRevert(abi.encodeWithSelector(SwarmbrainToken.ERC20InsufficientAllowance.selector, ALICE, 99, 100));
        vm.prank(ALICE);
        token.transferFrom(FACTORY, BOB, 100);
        assertEq(token.allowance(FACTORY, ALICE), 99, "allowance untouched after the revert");
    }

    function test_transferFromRevertsWhenBalanceInsufficientDespiteAllowance() public {
        vm.prank(ALICE);
        token.approve(BOB, 1_000);
        vm.expectRevert(abi.encodeWithSelector(SwarmbrainToken.ERC20InsufficientBalance.selector, ALICE, 0, 10));
        vm.prank(BOB);
        token.transferFrom(ALICE, CAROL, 10);
    }

    function test_transferFromRevertsToZeroAddressEvenWithInfiniteAllowance() public {
        vm.prank(FACTORY);
        token.approve(ALICE, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(SwarmbrainToken.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(ALICE);
        token.transferFrom(FACTORY, address(0), 1);
        assertEq(token.totalSupply(), SUPPLY, "nothing burned");
    }

    // ---------------------------------------------------------------------
    // Fixed supply and no privileged hand
    // ---------------------------------------------------------------------

    /// @dev The token exposes no mint, owner, upgrade or minter entry point. Each common selector is
    ///      tried from a stranger and from the deployer; every call must fail and the supply and the
    ///      caller's balance must be unchanged.
    function test_noMintOrAdminEntryPointExists() public {
        string[10] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], ATTACKER, type(uint128).max);
            vm.prank(ATTACKER);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            vm.prank(FACTORY);
            (ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            assertEq(token.totalSupply(), SUPPLY, signatures[i]);
            assertEq(token.balanceOf(ATTACKER), 0, signatures[i]);
        }
    }

    function test_noOwnerAccessor() public {
        (bool ok,) = address(token).call(abi.encodeWithSignature("owner()"));
        assertFalse(ok, "the token has no owner");
    }

    /// @dev No pause, blocklist, freeze, lock or seizure path exists. After every such attempt from
    ///      the deployer, the holder still holds what it held and can still transfer.
    function test_noPrivilegedCallMovesOrFreezesAHolder() public {
        vm.prank(FACTORY);
        token.transfer(ALICE, SUPPLY / 1_000);
        uint256 held = token.balanceOf(ALICE);
        assertGt(held, 0, "alice received something");

        string[12] memory signatures = [
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "seize(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], ALICE, true);
            vm.prank(FACTORY);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
        }
        // The deployer cannot pull from a holder without an allowance either.
        vm.prank(FACTORY);
        (bool pulled,) =
            address(token).call(abi.encodeWithSelector(token.transferFrom.selector, ALICE, FACTORY, uint256(1)));
        assertFalse(pulled, "the deployer pulled without an allowance");

        assertEq(token.balanceOf(ALICE), held, "alice still holds what she held");
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, held / 2), "alice can still transfer");
        assertEq(token.balanceOf(BOB), held / 2, "bob received the full half");
    }

    // ---------------------------------------------------------------------
    // Launch flows: every transfer moves exactly what it says
    // ---------------------------------------------------------------------

    /// @dev Mirrors the launch: ten percent to the distributor, a claim out of it, half to the pool,
    ///      a buy and a sell through the pool, the remainder to the requester. Nothing is taxed,
    ///      and the supply never changes.
    function test_launchFlowsArriveWhole() public {
        uint256 swarm = (SUPPLY * 1_000) / 10_000;
        uint256 poolShare = (SUPPLY * 5_000) / 10_000;
        uint256 remainder = SUPPLY - swarm - poolShare;

        vm.startPrank(FACTORY);
        assertTrue(token.transfer(DISTRIBUTOR, swarm), "distributor transfer returned false");
        assertTrue(token.transfer(POOL, poolShare), "pool transfer returned false");
        assertTrue(token.transfer(CAROL, remainder), "remainder transfer returned false");
        vm.stopPrank();
        assertEq(token.balanceOf(DISTRIBUTOR), swarm, "the swarm's share arrived whole");
        assertEq(token.balanceOf(POOL), poolShare, "the pool's share arrived whole");
        assertEq(token.balanceOf(CAROL), remainder, "the remainder arrived whole");
        assertEq(token.balanceOf(FACTORY), 0, "the factory paid everything out");

        // A contributor claims the whole distributor balance.
        vm.prank(DISTRIBUTOR);
        token.transfer(ALICE, swarm);
        assertEq(token.balanceOf(ALICE), swarm, "the claim arrived whole");
        assertEq(token.balanceOf(DISTRIBUTOR), 0, "the distributor kept nothing back");

        // A trader buys from the pool and sells back exactly what it bought.
        uint256 bought = 12_345 * 10 ** 18;
        vm.prank(POOL);
        token.transfer(BOB, bought);
        assertEq(token.balanceOf(BOB), bought, "the buy arrived whole");
        vm.prank(BOB);
        token.approve(POOL, bought);
        vm.prank(POOL);
        token.transferFrom(BOB, POOL, bought);
        assertEq(token.balanceOf(BOB), 0, "the sell took everything offered");
        assertEq(token.balanceOf(POOL), poolShare, "the pool is whole again");

        assertEq(token.totalSupply(), SUPPLY, "the launch flows changed the supply");
    }

    // ---------------------------------------------------------------------
    // Fuzz
    // ---------------------------------------------------------------------

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != FACTORY);
        amount = bound(amount, 0, SUPPLY);
        vm.prank(FACTORY);
        assertTrue(token.transfer(to, amount), "transfer returned false");
        assertEq(token.balanceOf(to), amount, "receiver got exactly the amount");
        assertEq(token.balanceOf(FACTORY), SUPPLY - amount, "sender paid exactly the amount");
        assertEq(token.balanceOf(to) + token.balanceOf(FACTORY), SUPPLY, "balances sum to the supply");
        assertEq(token.totalSupply(), SUPPLY, "supply unchanged");
    }

    function testFuzz_transferRevertsAboveBalance(uint256 amount) public {
        amount = bound(amount, SUPPLY + 1, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(SwarmbrainToken.ERC20InsufficientBalance.selector, FACTORY, SUPPLY, amount)
        );
        vm.prank(FACTORY);
        token.transfer(ALICE, amount);
    }

    function testFuzz_transferFromRespectsAllowance(uint256 allowanceAmount, uint256 spend) public {
        allowanceAmount = bound(allowanceAmount, 0, SUPPLY);
        spend = bound(spend, 0, SUPPLY);
        vm.prank(FACTORY);
        token.approve(ALICE, allowanceAmount);

        if (spend > allowanceAmount) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    SwarmbrainToken.ERC20InsufficientAllowance.selector, ALICE, allowanceAmount, spend
                )
            );
            vm.prank(ALICE);
            token.transferFrom(FACTORY, BOB, spend);
            assertEq(token.balanceOf(BOB), 0, "nothing moved");
            assertEq(token.allowance(FACTORY, ALICE), allowanceAmount, "allowance untouched");
        } else {
            vm.prank(ALICE);
            assertTrue(token.transferFrom(FACTORY, BOB, spend), "transferFrom returned false");
            assertEq(token.balanceOf(BOB), spend, "bob received exactly the amount");
            assertEq(token.allowance(FACTORY, ALICE), allowanceAmount - spend, "allowance reduced exactly");
        }
        assertEq(token.totalSupply(), SUPPLY, "supply unchanged");
    }

    function testFuzz_approveSetsExactAllowance(address spender, uint256 value) public {
        vm.assume(spender != address(0));
        uint256 spenderBalanceBefore = token.balanceOf(spender);
        vm.prank(ALICE);
        assertTrue(token.approve(spender, value), "approve returned false");
        assertEq(token.allowance(ALICE, spender), value, "allowance is exactly the value");
        assertEq(token.balanceOf(spender), spenderBalanceBefore, "approving moves nothing");
        assertEq(token.totalSupply(), SUPPLY, "supply unchanged");
    }

    function testFuzz_chainedTransfersConserveSupply(uint256 first, uint256 second) public {
        first = bound(first, 0, SUPPLY);
        second = bound(second, 0, first);
        vm.prank(FACTORY);
        token.transfer(ALICE, first);
        vm.prank(ALICE);
        token.transfer(BOB, second);
        assertEq(token.balanceOf(FACTORY), SUPPLY - first, "factory");
        assertEq(token.balanceOf(ALICE), first - second, "alice");
        assertEq(token.balanceOf(BOB), second, "bob");
        assertEq(token.totalSupply(), SUPPLY, "supply unchanged");
    }
}
