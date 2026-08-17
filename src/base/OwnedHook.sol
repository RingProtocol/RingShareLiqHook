// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BaseHook} from "../utils/BaseHook.sol";

/// @title OwnedHook
/// @notice Single-admin base for hooks that hold the operator's own capital: the admin identity, a
///         two-step transfer of it, and a global kill switch.
///
///         The admin is the single trust principal. It configures pools and moves the hook's
///         reserves, so key rotation has to be possible — an admin that cannot be transferred means
///         a leaked key cannot be revoked and a lost key locks the reserves permanently, since every
///         withdrawal path is `onlyAdmin`. The transfer is two-step so a mistyped address cannot
///         produce exactly that outcome.
///
///         There is deliberately no "renounce": every configuration and withdrawal entry point
///         would be bricked and every pool referencing the hook orphaned.
abstract contract OwnedHook is BaseHook {
    /// @dev Caller is not the admin, or is not the pending admin accepting a transfer.
    error Unauthorized();

    /// @dev A zero address was supplied where a real one is required.
    error InvalidAddress();

    /// @notice Emitted when a transfer is nominated. The nominee is not admin yet.
    event AdminTransferStarted(address indexed previousAdmin, address indexed newAdmin);

    /// @notice Emitted when a nominee accepts and becomes admin.
    event AdminTransferred(address indexed previousAdmin, address indexed newAdmin);

    /// @notice Emitted when the global kill switch is flipped.
    event PausedSet(bool paused);

    /// @notice The admin. Controls configuration and reserves.
    address public admin;

    /// @notice Nominated admin, pending its own {acceptAdmin} call.
    address public pendingAdmin;

    /// @notice Global kill switch across every pool the hook serves. What it stops is up to the
    ///         subclass, but it must never block swaps, LP exits or withdrawals — pausing is for
    ///         withholding the hook's own capital, not for trapping anyone else's.
    bool public paused;

    modifier onlyAdmin() {
        if (msg.sender != admin) revert Unauthorized();
        _;
    }

    constructor(IPoolManager _manager, address _admin) BaseHook(_manager) {
        if (_admin == address(0)) revert InvalidAddress();
        admin = _admin;
    }

    /// @notice Nominate a new admin. Takes effect only once the nominee calls {acceptAdmin}, so a
    ///         typo cannot lock the hook's reserves away.
    /// @param newAdmin The nominee. Pass `address(0)` to cancel a pending nomination.
    function transferAdmin(address newAdmin) external onlyAdmin {
        pendingAdmin = newAdmin;
        emit AdminTransferStarted(admin, newAdmin);
    }

    /// @notice Accept a pending admin transfer.
    function acceptAdmin() external {
        if (msg.sender != pendingAdmin) revert Unauthorized();
        address previous = admin;
        admin = msg.sender;
        pendingAdmin = address(0);
        emit AdminTransferred(previous, msg.sender);
    }

    /// @notice Flip the global kill switch.
    function setPaused(bool _paused) external onlyAdmin {
        paused = _paused;
        emit PausedSet(_paused);
    }
}
