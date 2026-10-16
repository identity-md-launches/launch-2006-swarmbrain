// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TestBase} from "./utils/TestBase.sol";
import {Vm} from "./utils/TestBase.sol";
import {SwarmbrainToken} from "../src/SwarmbrainToken.sol";

/// @notice Edge cases and failure paths that `SwarmbrainToken.t.sol` does not reach: the zero
///         address as a caller, zero-value calls that skip checks, the order in which checks fire,
///         the exact shape of the events, the deployment event, the runtime bytecode, and the
///         boundaries of the arithmetic. Property tests pin the same edges over random inputs.
/// forge-config: default.fuzz.runs = 1000
contract SwarmbrainTokenEdgesTest is TestBase {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    bytes32 internal constant TRANSFER_SIG = keccak256("Transfer(address,address,uint256)");
    bytes32 internal constant APPROVAL_SIG = keccak256("Approval(address,address,uint256)");

    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;

    address internal constant FACTORY = address(0xFAC7);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA201);

    SwarmbrainToken internal token;

    function setUp() public {
        vm.prank(FACTORY);
        token = new SwarmbrainToken();
        vm.label(address(token), "SWARMBRA");
        vm.label(FACTORY, "factory");
        vm.label(ALICE, "alice");
        vm.label(BOB, "bob");
        vm.label(CAROL, "carol");
    }

    // ---------------------------------------------------------------------
    // Deployment
    // ---------------------------------------------------------------------

    function test_constructorEmitsMintTransferFromZero() public {
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), ALICE, SUPPLY);
        vm.prank(ALICE);
        new SwarmbrainToken();
    }

    function test_constructorEmitsExactlyOneEvent() public {
        vm.recordLogs();
        vm.prank(ALICE);
        SwarmbrainToken fresh = new SwarmbrainToken();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "the constructor emits exactly one event");
        assertEq(logs[0].emitter, address(fresh), "emitted by the token");
        assertEq(logs[0].topics.length, 3, "Transfer has two indexed arguments");
        assertEq(logs[0].topics[0], TRANSFER_SIG, "the event is Transfer");
        assertEq(address(uint160(uint256(logs[0].topics[1]))), address(0), "from the zero address");
        assertEq(address(uint160(uint256(logs[0].topics[2]))), ALICE, "to the deployer");
        assertEq(abi.decode(logs[0].data, (uint256)), SUPPLY, "of the whole supply");
    }

    function test_twoDeploymentsAreIndependent() public {
        vm.prank(ALICE);
        SwarmbrainToken other = new SwarmbrainToken();
        vm.prank(FACTORY);
        token.transfer(BOB, 5);
        assertEq(other.balanceOf(BOB), 0, "the other token saw nothing");
        assertEq(other.balanceOf(ALICE), SUPPLY, "the other token's deployer holds its supply");
        assertEq(token.balanceOf(ALICE), 0, "alice holds none of the first token");
        assertEq(other.totalSupply() + token.totalSupply(), 2 * SUPPLY, "each has its own supply");
    }

    /// @dev Mirrors the launch floor: no DELEGATECALL, CALLCODE or SELFDESTRUCT in the runtime, with
    ///      PUSH data skipped so a pushed constant cannot be mistaken for an opcode.
    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0, "no runtime");
        assertLe(runtime.length, 24_576, "runtime exceeds EIP-170");
        for (uint256 i = 0; i < runtime.length; i++) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL in runtime");
            assertTrue(op != 0xF2, "CALLCODE in runtime");
            assertTrue(op != 0xFF, "SELFDESTRUCT in runtime");
        }
    }

    // ---------------------------------------------------------------------
    // The zero address as a caller
    // ---------------------------------------------------------------------

    function test_transferFromZeroAddressSenderReverts() public {
        vm.expectRevert(abi.encodeWithSelector(SwarmbrainToken.ERC20InvalidSender.selector, address(0)));
        vm.prank(address(0));
        token.transfer(ALICE, 0);
    }

    function test_transferFromZeroAddressSenderRevertsBeforeBalanceCheck() public {
        // The sender check fires before the balance check, so the error is InvalidSender, not InsufficientBalance.
        vm.expectRevert(abi.encodeWithSelector(SwarmbrainToken.ERC20InvalidSender.selector, address(0)));
        vm.prank(address(0));
        token.transfer(ALICE, 1);
    }

    function test_approveFromZeroAddressReverts() public {
        vm.expectRevert(abi.encodeWithSelector(SwarmbrainToken.ERC20InvalidApprover.selector, address(0)));
        vm.prank(address(0));
        token.approve(ALICE, 1);
        assertEq(token.allowance(address(0), ALICE), 0, "no allowance was recorded");
    }

    function test_approveZeroToZeroRevertsAsApprover() public {
        // Both are invalid; the approver check fires first.
        vm.expectRevert(abi.encodeWithSelector(SwarmbrainToken.ERC20InvalidApprover.selector, address(0)));
        vm.prank(address(0));
        token.approve(address(0), 1);
    }

    function test_transferFromTheZeroAddressRevertsOnAllowanceForAnyPositiveAmount() public {
        // Nobody can hold an allowance from the zero address, so pulling from it fails on the allowance.
        vm.expectRevert(abi.encodeWithSelector(SwarmbrainToken.ERC20InsufficientAllowance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transferFrom(address(0), BOB, 1);
    }

    function test_transferFromTheZeroAddressOfZeroRevertsAsInvalidSender() public {
        // A zero amount passes the allowance check (0 < 0 is false) and then hits the sender check.
        vm.expectRevert(abi.encodeWithSelector(SwarmbrainToken.ERC20InvalidSender.selector, address(0)));
        vm.prank(ALICE);
        token.transferFrom(address(0), BOB, 0);
    }

    function test_transferToZeroOfZeroStillReverts() public {
        vm.expectRevert(abi.encodeWithSelector(SwarmbrainToken.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(ALICE);
        token.transfer(address(0), 0);
    }

    // ---------------------------------------------------------------------
    // transferFrom: zero values, self, and the order of checks
    // ---------------------------------------------------------------------

    function test_transferFromZeroValueWithoutAllowanceSucceedsAndMovesNothing() public {
        assertEq(token.allowance(FACTORY, ALICE), 0, "precondition: no allowance");
        vm.expectEmit(true, true, false, true);
        emit Transfer(FACTORY, BOB, 0);
        vm.prank(ALICE);
        assertTrue(token.transferFrom(FACTORY, BOB, 0), "zero transferFrom returns true");
        assertEq(token.balanceOf(BOB), 0, "nothing moved");
        assertEq(token.balanceOf(FACTORY), SUPPLY, "nothing moved");
        assertEq(token.allowance(FACTORY, ALICE), 0, "allowance still zero");
    }

    function test_transferFromBySenderItselfNeedsAnAllowance() public {
        // OpenZeppelin v5 semantics: msg.sender == from does not bypass the allowance.
        vm.expectRevert(abi.encodeWithSelector(SwarmbrainToken.ERC20InsufficientAllowance.selector, FACTORY, 0, 1));
        vm.prank(FACTORY);
        token.transferFrom(FACTORY, ALICE, 1);
    }

    function test_transferFromBySenderItselfWithSelfAllowanceWorks() public {
        vm.prank(FACTORY);
        token.approve(FACTORY, 10);
        vm.prank(FACTORY);
        token.transferFrom(FACTORY, ALICE, 7);
        assertEq(token.balanceOf(ALICE), 7, "alice received");
        assertEq(token.allowance(FACTORY, FACTORY), 3, "self allowance decremented");
    }

    function test_transferFromToTheOwnerKeepsBalanceAndSpendsAllowance() public {
        vm.prank(FACTORY);
        token.approve(ALICE, 100);
        vm.prank(ALICE);
        token.transferFrom(FACTORY, FACTORY, 60);
        assertEq(token.balanceOf(FACTORY), SUPPLY, "self transfer keeps the balance");
        assertEq(token.allowance(FACTORY, ALICE), 40, "the allowance was still spent");
    }

    function test_transferFromToTheSpender() public {
        vm.prank(FACTORY);
        token.approve(ALICE, 100);
        vm.prank(ALICE);
        token.transferFrom(FACTORY, ALICE, 100);
        assertEq(token.balanceOf(ALICE), 100, "the spender received");
        assertEq(token.allowance(FACTORY, ALICE), 0, "allowance spent");
    }

    function test_allowanceIsCheckedBeforeBalance() public {
        // Alice holds nothing and has granted Bob 5: a pull of 10 fails on the allowance, not the balance.
        vm.prank(ALICE);
        token.approve(BOB, 5);
        vm.expectRevert(abi.encodeWithSelector(SwarmbrainToken.ERC20InsufficientAllowance.selector, BOB, 5, 10));
        vm.prank(BOB);
        token.transferFrom(ALICE, CAROL, 10);
    }

    function test_infiniteAllowanceStillRespectsBalance() public {
        vm.prank(ALICE);
        token.approve(BOB, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(SwarmbrainToken.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        vm.prank(BOB);
        token.transferFrom(ALICE, CAROL, 1);
        assertEq(token.allowance(ALICE, BOB), type(uint256).max, "allowance untouched after the revert");
    }

    function test_maxMinusOneAllowanceIsFiniteAndDecrements() public {
        vm.prank(FACTORY);
        token.approve(ALICE, type(uint256).max - 1);
        vm.prank(ALICE);
        token.transferFrom(FACTORY, BOB, 1);
        assertEq(token.allowance(FACTORY, ALICE), type(uint256).max - 2, "only exactly max is infinite");
    }

    function test_allowanceCanBeRaisedAndLoweredWhileSpending() public {
        vm.prank(FACTORY);
        token.approve(ALICE, 10);
        vm.prank(ALICE);
        token.transferFrom(FACTORY, BOB, 4);
        vm.prank(FACTORY);
        token.approve(ALICE, 2);
        vm.expectRevert(abi.encodeWithSelector(SwarmbrainToken.ERC20InsufficientAllowance.selector, ALICE, 2, 3));
        vm.prank(ALICE);
        token.transferFrom(FACTORY, BOB, 3);
        vm.prank(ALICE);
        token.transferFrom(FACTORY, BOB, 2);
        assertEq(token.allowance(FACTORY, ALICE), 0, "spent down to zero");
        assertEq(token.balanceOf(BOB), 6, "bob received 4 + 2");
    }

    // ---------------------------------------------------------------------
    // Event shape
    // ---------------------------------------------------------------------

    function test_transferEmitsExactlyOneEvent() public {
        vm.recordLogs();
        vm.prank(FACTORY);
        token.transfer(ALICE, 9);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "exactly one event");
        assertEq(logs[0].topics[0], TRANSFER_SIG, "it is Transfer");
        assertEq(address(uint160(uint256(logs[0].topics[1]))), FACTORY, "from");
        assertEq(address(uint160(uint256(logs[0].topics[2]))), ALICE, "to");
        assertEq(abi.decode(logs[0].data, (uint256)), 9, "value");
    }

    function test_transferFromEmitsOnlyTransferNoApproval() public {
        vm.prank(FACTORY);
        token.approve(ALICE, 50);
        vm.recordLogs();
        vm.prank(ALICE);
        token.transferFrom(FACTORY, BOB, 20);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "transferFrom emits exactly one event");
        assertEq(logs[0].topics[0], TRANSFER_SIG, "it is Transfer, not Approval");
        assertEq(address(uint160(uint256(logs[0].topics[1]))), FACTORY, "from the owner, not the spender");
        assertEq(address(uint160(uint256(logs[0].topics[2]))), BOB, "to");
        assertEq(abi.decode(logs[0].data, (uint256)), 20, "value");
        assertEq(token.allowance(FACTORY, ALICE), 30, "allowance decremented silently");
    }

    function test_approveEmitsExactlyOneApproval() public {
        vm.recordLogs();
        vm.prank(FACTORY);
        token.approve(ALICE, 77);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "exactly one event");
        assertEq(logs[0].topics[0], APPROVAL_SIG, "it is Approval");
        assertEq(address(uint160(uint256(logs[0].topics[1]))), FACTORY, "owner");
        assertEq(address(uint160(uint256(logs[0].topics[2]))), ALICE, "spender");
        assertEq(abi.decode(logs[0].data, (uint256)), 77, "value");
    }

    function test_failedTransferEmitsNothing() public {
        vm.recordLogs();
        vm.prank(ALICE);
        (bool ok,) = address(token).call(abi.encodeCall(token.transfer, (BOB, 1)));
        assertFalse(ok, "the transfer failed");
        assertEq(vm.getRecordedLogs().length, 0, "a reverted call leaves no event");
    }

    // ---------------------------------------------------------------------
    // Arithmetic boundaries
    // ---------------------------------------------------------------------

    function test_transferMaxUintReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                SwarmbrainToken.ERC20InsufficientBalance.selector, FACTORY, SUPPLY, type(uint256).max
            )
        );
        vm.prank(FACTORY);
        token.transfer(ALICE, type(uint256).max);
    }

    function test_wholeSupplyRoundTripsBetweenHolders() public {
        vm.prank(FACTORY);
        token.transfer(ALICE, SUPPLY);
        vm.prank(ALICE);
        token.transfer(BOB, SUPPLY);
        vm.prank(BOB);
        token.transfer(FACTORY, SUPPLY);
        assertEq(token.balanceOf(FACTORY), SUPPLY, "back where it started");
        assertEq(token.balanceOf(ALICE), 0, "alice empty");
        assertEq(token.balanceOf(BOB), 0, "bob empty");
    }

    function test_holderCanDrainToOneWeiAndThenTheLastWei() public {
        vm.prank(FACTORY);
        token.transfer(ALICE, 2);
        vm.prank(ALICE);
        token.transfer(BOB, 1);
        vm.prank(ALICE);
        token.transfer(BOB, 1);
        assertEq(token.balanceOf(ALICE), 0, "drained");
        vm.expectRevert(abi.encodeWithSelector(SwarmbrainToken.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transfer(BOB, 1);
    }

    /// @dev Standard ERC-20 behaviour, recorded rather than hidden: the token contract is an ordinary
    ///      receiver, and what lands there has no owner and no recovery path.
    function test_tokensSentToTheTokenContractAreAcceptedAndStuck() public {
        vm.prank(FACTORY);
        assertTrue(token.transfer(address(token), 1), "the token accepts itself as a receiver");
        assertEq(token.balanceOf(address(token)), 1, "it now holds one wei of itself");
        (bool ok,) = address(token).call(abi.encodeWithSignature("recover(address,uint256)", FACTORY, 1));
        assertFalse(ok, "there is no recovery entry point");
        (ok,) = address(token).call(abi.encodeWithSignature("rescueTokens(address,address,uint256)", token, FACTORY, 1));
        assertFalse(ok, "there is no rescue entry point");
        assertEq(token.balanceOf(address(token)), 1, "still stuck");
        assertEq(token.totalSupply(), SUPPLY, "still counted in the supply");
    }

    function test_callingWithEtherReverts() public {
        vm.deal(ALICE, 1 ether);
        vm.prank(ALICE);
        (bool ok,) = address(token).call{value: 1}("");
        assertFalse(ok, "the token has no receive or fallback");
        vm.prank(ALICE);
        (ok,) = address(token).call{value: 1}(abi.encodeCall(token.transfer, (BOB, 0)));
        assertFalse(ok, "transfer is not payable");
        assertEq(address(token).balance, 0, "the token holds no ether");
    }

    function test_unknownSelectorReverts() public {
        (bool ok,) = address(token).call(abi.encodeWithSignature("nothingHere()"));
        assertFalse(ok, "no fallback accepts unknown calls");
        (ok,) = address(token).call("");
        assertFalse(ok, "no receive accepts empty calls");
    }

    // ---------------------------------------------------------------------
    // Property tests over the same edges
    // ---------------------------------------------------------------------

    /// @dev Any address other than the deployer starts empty and cannot send a single wei.
    function testFuzz_emptyHolderCannotSendAnyPositiveAmount(address sender, address to, uint256 amount) public {
        sender = _notDeployerOrZero(sender);
        to = _nonZero(to);
        amount = bound(amount, 1, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(SwarmbrainToken.ERC20InsufficientBalance.selector, sender, 0, amount));
        vm.prank(sender);
        token.transfer(to, amount);
    }

    /// @dev For any balance and any amount, transfer succeeds iff amount <= balance, and the outcome
    ///      is exact either way.
    function testFuzz_transferSucceedsIffAmountWithinBalance(uint256 balance, uint256 amount) public {
        balance = bound(balance, 0, SUPPLY);
        vm.prank(FACTORY);
        token.transfer(ALICE, balance);

        vm.prank(ALICE);
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(token.transfer, (BOB, amount)));
        if (amount <= balance) {
            assertTrue(ok, "a transfer within the balance failed");
            assertEq(token.balanceOf(ALICE), balance - amount, "sender debited exactly");
            assertEq(token.balanceOf(BOB), amount, "receiver credited exactly");
        } else {
            assertFalse(ok, "a transfer above the balance succeeded");
            assertEq(
                ret,
                abi.encodeWithSelector(SwarmbrainToken.ERC20InsufficientBalance.selector, ALICE, balance, amount),
                "wrong revert data"
            );
            assertEq(token.balanceOf(ALICE), balance, "sender untouched");
            assertEq(token.balanceOf(BOB), 0, "receiver untouched");
        }
        assertEq(token.balanceOf(ALICE) + token.balanceOf(BOB) + token.balanceOf(FACTORY), SUPPLY, "conserved");
    }

    /// @dev The infinite allowance survives any number of spends of any size within the balance.
    function testFuzz_infiniteAllowanceSurvivesRepeatedSpends(uint256 spends, uint256 seed) public {
        spends = bound(spends, 1, 20);
        vm.prank(FACTORY);
        token.approve(ALICE, type(uint256).max);
        uint256 moved;
        for (uint256 i = 0; i < spends; i++) {
            uint256 remaining = token.balanceOf(FACTORY);
            uint256 amount = bound(uint256(keccak256(abi.encode(seed, i))), 0, remaining);
            vm.prank(ALICE);
            token.transferFrom(FACTORY, BOB, amount);
            moved += amount;
            assertEq(token.allowance(FACTORY, ALICE), type(uint256).max, "infinite allowance decremented");
        }
        assertEq(token.balanceOf(BOB), moved, "bob received the sum");
        assertEq(token.balanceOf(FACTORY), SUPPLY - moved, "factory paid the sum");
    }

    /// @dev Finite allowances are spent down exactly and independently per spender.
    function testFuzz_twoSpendersHaveIndependentAllowances(uint256 a, uint256 b, uint256 spendA) public {
        a = bound(a, 0, SUPPLY / 2);
        b = bound(b, 0, SUPPLY / 2);
        spendA = bound(spendA, 0, a);
        vm.startPrank(FACTORY);
        token.approve(ALICE, a);
        token.approve(BOB, b);
        vm.stopPrank();
        vm.prank(ALICE);
        token.transferFrom(FACTORY, CAROL, spendA);
        assertEq(token.allowance(FACTORY, ALICE), a - spendA, "alice's allowance spent exactly");
        assertEq(token.allowance(FACTORY, BOB), b, "bob's allowance untouched");
        assertEq(token.allowance(ALICE, FACTORY), 0, "the reverse direction is untouched");
    }

    /// @dev The latest approve always wins, whatever came before, for any owner/spender pair.
    function testFuzz_latestApproveWins(address owner, address spender, uint256 first, uint256 second) public {
        owner = _nonZero(owner);
        spender = _nonZero(spender);
        vm.startPrank(owner);
        token.approve(spender, first);
        token.approve(spender, second);
        vm.stopPrank();
        assertEq(token.allowance(owner, spender), second, "latest approve wins");
    }

    /// @dev Approvals never move tokens and never change the supply, for any pair and any value.
    function testFuzz_approveNeverMovesTokens(address owner, address spender, uint256 value) public {
        owner = _nonZero(owner);
        spender = _nonZero(spender);
        uint256 ownerBefore = token.balanceOf(owner);
        uint256 spenderBefore = token.balanceOf(spender);
        vm.prank(owner);
        token.approve(spender, value);
        assertEq(token.balanceOf(owner), ownerBefore, "owner's balance moved");
        assertEq(token.balanceOf(spender), spenderBefore, "spender's balance moved");
        assertEq(token.totalSupply(), SUPPLY, "supply moved");
    }

    /// @dev A transfer of the full balance leaves exactly zero, and one more wei is refused.
    function testFuzz_fullBalanceTransferLeavesZero(uint256 balance) public {
        balance = bound(balance, 1, SUPPLY);
        vm.prank(FACTORY);
        token.transfer(ALICE, balance);
        vm.prank(ALICE);
        token.transfer(BOB, balance);
        assertEq(token.balanceOf(ALICE), 0, "exactly zero left");
        vm.expectRevert(abi.encodeWithSelector(SwarmbrainToken.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transfer(BOB, 1);
    }

    // ---------------------------------------------------------------------
    // Input shaping (bound-style, so no run is discarded)
    // ---------------------------------------------------------------------

    function _nonZero(address a) internal pure returns (address) {
        return a == address(0) ? address(1) : a;
    }

    function _notDeployerOrZero(address a) internal pure returns (address) {
        if (a == address(0) || a == FACTORY) return address(2);
        return a;
    }
}
