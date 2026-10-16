// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The subset of Foundry's cheatcode interface these tests use. Foundry dispatches on the
///         cheatcode address and selector, so this local declaration works exactly like forge-std's
///         `Vm` for these functions. Declared here so the project has no external dependency to vendor.
interface Vm {
    /// @notice Sets `msg.sender` for the next call (or contract creation) that is not a cheatcode.
    function prank(address msgSender) external;

    /// @notice Sets `msg.sender` for every following call until `stopPrank`.
    function startPrank(address msgSender) external;

    /// @notice Ends a `startPrank`.
    function stopPrank() external;

    /// @notice Expects the next call to revert with any data.
    function expectRevert() external;

    /// @notice Expects the next call to revert with exactly `revertData`.
    function expectRevert(bytes calldata revertData) external;

    /// @notice Expects the next call to emit an event matching the one emitted right after this cheat.
    function expectEmit(bool checkTopic1, bool checkTopic2, bool checkTopic3, bool checkData) external;

    /// @notice Discards the current fuzz input when `condition` is false.
    function assume(bool condition) external pure;

    /// @notice Labels an address in traces.
    function label(address account, string calldata newLabel) external;

    /// @notice Sets the ether balance of `account`.
    function deal(address account, uint256 newBalance) external;

    /// @notice An event recorded by `recordLogs`.
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    /// @notice Starts recording every event emitted from now on.
    function recordLogs() external;

    /// @notice Returns the events recorded since `recordLogs` and clears the recording.
    function getRecordedLogs() external returns (Log[] memory logs);
}

/// @notice A small assertion base for the tests: every assertion reverts with its message on failure,
///         which Foundry reports as a failed test.
abstract contract TestBase {
    /// @dev The well-known cheatcode address: `address(uint160(uint256(keccak256("hevm cheat code"))))`.
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function assertTrue(bool condition, string memory err) internal pure {
        require(condition, err);
    }

    function assertFalse(bool condition, string memory err) internal pure {
        require(!condition, err);
    }

    function assertEq(uint256 a, uint256 b, string memory err) internal pure {
        require(a == b, err);
    }

    function assertEq(address a, address b, string memory err) internal pure {
        require(a == b, err);
    }

    function assertEq(string memory a, string memory b, string memory err) internal pure {
        require(keccak256(bytes(a)) == keccak256(bytes(b)), err);
    }

    function assertEq(bytes memory a, bytes memory b, string memory err) internal pure {
        require(keccak256(a) == keccak256(b), err);
    }

    function assertEq(bytes32 a, bytes32 b, string memory err) internal pure {
        require(a == b, err);
    }

    function assertLe(uint256 a, uint256 b, string memory err) internal pure {
        require(a <= b, err);
    }

    function assertGe(uint256 a, uint256 b, string memory err) internal pure {
        require(a >= b, err);
    }

    function assertGt(uint256 a, uint256 b, string memory err) internal pure {
        require(a > b, err);
    }

    /// @notice Maps any fuzz input into `[min, max]`, inclusive.
    function bound(uint256 x, uint256 min, uint256 max) internal pure returns (uint256) {
        require(min <= max, "bound: min > max");
        if (min == 0 && max == type(uint256).max) return x;
        uint256 size = max - min + 1;
        return min + (x % size);
    }
}
