// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @dev Transient-storage namespace seed for the per-pool JIT lock. Combined with a `PoolId` to
///      derive a per-pool slot; see {jitLockFor}. Kept identical to the prior `JITLockable`
///      abstract contract so the lock slots are bit-for-bit unchanged across this refactor.
bytes32 constant JIT_LOCK_NAMESPACE = keccak256("alf.jitlockable.lock.v1");

/// @dev Transient slot for the global "any JIT in flight" flag, shared across every pool a hook
///      serves. Set by {enter}, cleared by {clear}, and read by {anyJITInProgress}.
bytes32 constant JIT_GLOBAL_COUNTER_SLOT = keccak256("alf.jitlockable.global.v1");

/// @dev A user-facing or admin entry point was called from inside an active JIT cycle anywhere in
///      the hook, or `beforeSwap` was re-entered for an already-locked pool.
error JITInProgress();

/// @title JITLock
/// @author Uniswap Labs
/// @notice The transient per-pool JIT-cycle reentrancy lock, as a type-driven value. A JIT hook
///         derives one `JITLock` per pool via {jitLockFor}, calls {enter} at the top of a cycle
///         (`beforeSwap`) and {clear} at the end (`afterSwap`), and gates its external user/admin
///         entry points on {requireJITNotInProgress}.
///
///         Two transient slots cover two distinct reentrancy paths:
///
///         1. **Per-pool lock** (this type's wrapped slot): set by {enter}, cleared by {clear}.
///            {enter} rejects same-pool reentry, which would otherwise corrupt the lifecycle: an
///            inner cycle's {clear} would zero the slot while the outer cycle is still mid-flight,
///            orphaning the outer's deployed positions.
///         2. **Global in-flight flag** ({JIT_GLOBAL_COUNTER_SLOT}): a single process-wide slot
///            set and cleared alongside the per-pool lock. {requireJITNotInProgress}
///            reads it to reject cross-pool reentry, e.g. a vault callback during pool A's cycle
///            calling into pool B's entry points; a per-pool lock alone would leave that open.
///
///         The slots are namespaced via `keccak256` so they cannot collide with OpenZeppelin's
///         `ReentrancyGuardTransient` slot or any other transient state in the consumer. Transient
///         storage is used because the locks live only for one `beforeSwap`/`afterSwap` pair and
///         the flag returns to zero by transaction end.
/// @custom:security-contact security@uniswap.org
type JITLock is bytes32;

using {enter, clear} for JITLock global;

/// @notice Derive the per-pool JIT lock for `poolId`.
/// @dev One keccak per pool. Per-pool scoping is required so cross-pool reentry cannot clear
///      pool A's lock when pool B's `afterSwap` runs.
/// @param poolId The pool whose lock slot to address.
/// @return The per-pool transient lock.
function jitLockFor(PoolId poolId) pure returns (JITLock) {
    return JITLock.wrap(keccak256(abi.encode(JIT_LOCK_NAMESPACE, poolId)));
}

/// @notice Enter the per-pool JIT lock and set the global in-flight flag.
/// @dev Call at the top of a JIT cycle. Reverts {JITInProgress} when any JIT cycle is already in
///      flight. Checking the global slot here is required because `beforeSwap` is not an admin
///      entry point and therefore does not pass through {requireJITNotInProgress}.
/// @param self The pool's JIT lock.
function enter(JITLock self) {
    bytes32 perPool = JITLock.unwrap(self);
    bytes32 global = JIT_GLOBAL_COUNTER_SLOT;
    bool locked;
    assembly ("memory-safe") {
        locked := or(tload(perPool), tload(global))
    }
    if (locked) revert JITInProgress();
    assembly ("memory-safe") {
        tstore(perPool, 1)
        tstore(global, 1)
    }
}

/// @notice Clear the per-pool JIT lock and global in-flight flag.
/// @dev Call at the end of a JIT cycle after a successful {enter}. The pairing is structurally
///      enforced by the hook's begin/end JIT cycle ({enter} in `beforeSwap`, {clear} in
///      `afterSwap`), so {clear} is never reached without a preceding {enter}.
/// @param self The pool's JIT lock.
function clear(JITLock self) {
    bytes32 perPool = JITLock.unwrap(self);
    bytes32 global = JIT_GLOBAL_COUNTER_SLOT;
    assembly ("memory-safe") {
        tstore(perPool, 0)
        tstore(global, 0)
    }
}

/// @notice Whether any pool served by the hook has a JIT cycle in flight.
/// @dev Reads the global flag, not a per-pool slot, so it takes no `JITLock` self.
/// @return inProgress True if the global in-flight flag is non-zero.
function anyJITInProgress() view returns (bool inProgress) {
    bytes32 slot = JIT_GLOBAL_COUNTER_SLOT;
    assembly ("memory-safe") {
        inProgress := iszero(iszero(tload(slot)))
    }
}

/// @notice Revert {JITInProgress} if any pool served by the hook has a JIT cycle in flight.
/// @dev The guard for external user/admin entry points whose effects would conflict with
///      mid-flight JIT state. Consumers wrap this in a thin `whenJITNotInProgress` modifier so the
///      guard stays visible in each function signature and is hard to omit.
function requireJITNotInProgress() view {
    if (anyJITInProgress()) revert JITInProgress();
}
