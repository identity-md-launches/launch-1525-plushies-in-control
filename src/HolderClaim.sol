// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IFWAIRPFP} from "./interfaces/IFWAIRPFP.sol";

/// @title HolderClaim
/// @notice Twenty-day PIC vesting attached to FWAIR PFP token IDs, payable only to their current holders.
/// @dev Fund with 800,000,000 PIC in the launch transaction. No owner, upgrades, or token recovery.
contract HolderClaim is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public constant PFP = 0x29f1cBC8eccD64B0cE777f5Da45c72C47383a620;
    uint256 public constant MIN_ID = 1;
    uint256 public constant MAX_ID = 111;
    uint256 public constant SHARE = uint256(800_000_000 * 1e18) / MAX_ID;
    uint256 public constant VESTING = 20 days;

    IERC20 public immutable token;
    uint256 public immutable START;

    /// @notice PIC base units already paid for each ID; never reset on NFT transfers or burns.
    mapping(uint256 id => uint256 amount) public claimed;

    error InvalidToken();
    error InvalidId(uint256 id);
    error NotHolder(uint256 id);

    event Claimed(address indexed account, uint256 indexed id, uint256 amount);

    /// @param token_ The PIC token deployed by the launch, resolved as $token.
    /// @dev No external calls or code checks: this constructor also deploys on an empty chain.
    constructor(address token_) {
        if (token_ == address(0)) revert InvalidToken();
        token = IERC20(token_);
        START = block.timestamp;
    }

    /// @notice Total PIC base units vested for a valid ID, including amounts already claimed.
    /// @dev All 111 IDs share the same schedule, even when burned or locked in the PFP contract.
    function vested(uint256 id) public view returns (uint256) {
        _validateId(id);
        return _vested();
    }

    /// @notice Current owner, or the recorded lock holder if the PFP contract owns the NFT.
    /// @return holder Zero when ownerOf reverts (including burns) or a lock has no recorded holder.
    function holderOf(uint256 id) public view returns (address holder) {
        _validateId(id);
        try IFWAIRPFP(PFP).ownerOf(id) returns (address owner) {
            if (owner != PFP) return owner;
        } catch {
            return address(0);
        }

        // Only consult the lock record while the NFT is actually owned by the PFP contract.
        // A failed lock lookup reverts; it must not authorize the PFP contract as the holder.
        (holder,) = IFWAIRPFP(PFP).tokenLocks(id);
    }

    /// @notice Vested minus previously claimed PIC for an ID, independent of its current holder.
    /// @dev A burned ID can have a positive accounting balance, but nobody can claim it.
    function claimable(uint256 id) public view returns (uint256) {
        return vested(id) - claimed[id];
    }

    /// @notice Sum of claimable PIC for distinct supplied IDs currently held by account.
    /// @dev Invalid IDs revert. Other holders and burned IDs are skipped. The zero account receives no entitlement.
    function claimableFor(address account, uint256[] calldata ids) external view returns (uint256 total) {
        uint256 seen = 0;
        uint256 unlocked = _vested();
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            _validateId(id);
            uint256 bit = uint256(1) << (id - MIN_ID);
            if ((seen & bit) != 0) continue;
            seen |= bit;
            if (account != address(0) && holderOf(id) == account) {
                total += unlocked - claimed[id];
            }
        }
    }

    /// @notice Claim each supplied ID's unpaid vesting into the current holder's wallet.
    /// @dev Every ID must belong to msg.sender, even if fully claimed. One invalid/unauthorized ID
    /// reverts the entire batch. Updating each ID before the single transfer also makes duplicates harmless.
    /// @return total PIC base units paid. Empty or fully claimed batches return zero without a token transfer.
    function claim(uint256[] calldata ids) external nonReentrant returns (uint256 total) {
        uint256 unlocked = _vested();
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            address holder = holderOf(id);
            if (holder == address(0) || holder != msg.sender) revert NotHolder(id);
            uint256 amount = unlocked - claimed[id];
            if (amount == 0) continue;

            claimed[id] = unlocked;
            total += amount;
            emit Claimed(msg.sender, id, amount);
        }

        if (total != 0) token.safeTransfer(msg.sender, total);
    }

    function _vested() private view returns (uint256) {
        uint256 elapsed = block.timestamp - START;
        if (elapsed >= VESTING) return SHARE;
        return SHARE * elapsed / VESTING;
    }

    function _validateId(uint256 id) private pure {
        if (id < MIN_ID || id > MAX_ID) revert InvalidId(id);
    }
}
