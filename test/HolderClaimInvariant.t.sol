// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {PICToken} from "../src/PICToken.sol";
import {HolderClaim} from "../src/HolderClaim.sol";
import {MockPFP} from "./mocks/MockPFP.sol";

/// @dev Independent accounting and ownership model driven by randomized actions.
contract ClaimHandler is Test {
    uint256 internal constant SHARE = uint256(800_000_000e18) / 111;
    HolderClaim public immutable distribution;
    MockPFP public immutable pfp;
    address[4] public actors;
    mapping(uint256 => address) public expectedHolder;
    mapping(uint256 => bool) public locked;
    mapping(uint256 => uint256) public expectedClaimed;
    mapping(address => uint256) public expectedPaid;
    uint256 public totalPaid;

    constructor(HolderClaim distribution_, MockPFP pfp_, address[4] memory actors_) {
        distribution = distribution_;
        pfp = pfp_;
        actors = actors_;
        for (uint256 id = 1; id <= 111; ++id) {
            expectedHolder[id] = actors_[0];
        }
    }

    function advanceTime(uint32 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 0, 3 days));
    }

    function transferNft(uint8 rawId, uint8 rawActor) external {
        uint256 id = uint256(rawId) % 111 + 1;
        address from = expectedHolder[id];
        if (from == address(0)) return;
        address to = actors[uint256(rawActor) % actors.length];
        if (locked[id]) {
            vm.prank(from);
            pfp.unlock(id);
            locked[id] = false;
        }
        vm.prank(from);
        pfp.transferFrom(from, to, id);
        expectedHolder[id] = to;
    }

    function toggleLock(uint8 rawId) external {
        uint256 id = uint256(rawId) % 111 + 1;
        address holder = expectedHolder[id];
        if (holder == address(0)) return;
        vm.prank(holder);
        if (locked[id]) pfp.unlock(id);
        else pfp.lock(id, 1);
        locked[id] = !locked[id];
    }

    function burnNft(uint8 rawId) external {
        uint256 id = uint256(rawId) % 111 + 1;
        if (expectedHolder[id] == address(0)) return;
        pfp.burn(id);
        expectedHolder[id] = address(0);
        locked[id] = false;
    }

    function claimOne(uint8 rawId, bool duplicate) external {
        uint256 id = uint256(rawId) % 111 + 1;
        address holder = expectedHolder[id];
        if (holder == address(0)) return;
        uint256[] memory ids = new uint256[](duplicate ? 3 : 1);
        for (uint256 i; i < ids.length; ++i) {
            ids[i] = id;
        }
        uint256 unlocked = _unlocked();
        uint256 expected = unlocked - expectedClaimed[id];
        assertEq(distribution.claimableFor(holder, ids), expected);
        vm.prank(holder);
        assertEq(distribution.claim(ids), expected);
        expectedClaimed[id] = unlocked;
        expectedPaid[holder] += expected;
        totalPaid += expected;
    }

    function claimBatch(uint8 rawActor) external {
        address holder = actors[uint256(rawActor) % actors.length];
        uint256 count;
        for (uint256 id = 1; id <= 111; ++id) {
            if (expectedHolder[id] == holder) ++count;
        }
        uint256[] memory ids = new uint256[](count);
        uint256 expected;
        uint256 cursor;
        uint256 unlocked = _unlocked();
        for (uint256 id = 1; id <= 111; ++id) {
            if (expectedHolder[id] != holder) continue;
            ids[cursor++] = id;
            expected += unlocked - expectedClaimed[id];
            expectedClaimed[id] = unlocked;
        }
        assertEq(distribution.claimableFor(holder, ids), expected);
        vm.prank(holder);
        assertEq(distribution.claim(ids), expected);
        expectedPaid[holder] += expected;
        totalPaid += expected;
    }

    function _unlocked() private view returns (uint256) {
        uint256 elapsed = block.timestamp - distribution.START();
        return SHARE * (elapsed > 20 days ? 20 days : elapsed) / 20 days;
    }
}

contract HolderClaimInvariantTest is StdInvariant, Test {
    uint256 internal constant ALLOCATION = 800_000_000e18;
    uint256 internal constant SHARE = ALLOCATION / 111;
    PICToken internal token;
    HolderClaim internal distribution;
    ClaimHandler internal handler;
    address[4] internal actors;

    function setUp() public {
        vm.warp(1_800_000_000);
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = makeAddr(string.concat("actor", vm.toString(i)));
        }
        token = new PICToken();
        distribution = new HolderClaim(address(token));
        vm.etch(distribution.PFP(), address(new MockPFP()).code);
        MockPFP pfp = MockPFP(distribution.PFP());
        pfp.initialize(actors[0]);
        token.transfer(address(distribution), ALLOCATION);
        handler = new ClaimHandler(distribution, pfp, actors);

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = ClaimHandler.advanceTime.selector;
        selectors[1] = ClaimHandler.transferNft.selector;
        selectors[2] = ClaimHandler.toggleLock.selector;
        selectors[3] = ClaimHandler.burnNft.selector;
        selectors[4] = ClaimHandler.claimOne.selector;
        selectors[5] = ClaimHandler.claimBatch.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_scheduleOwnershipAndConservation() public view {
        uint256 elapsed = block.timestamp - distribution.START();
        uint256 vested = SHARE * (elapsed > 20 days ? 20 days : elapsed) / 20 days;
        uint256 accounted;
        for (uint256 id = 1; id <= 111; ++id) {
            uint256 paid = distribution.claimed(id);
            assertEq(paid, handler.expectedClaimed(id));
            assertLe(paid, vested);
            assertEq(distribution.vested(id), vested);
            assertEq(distribution.claimable(id), vested - paid);
            assertEq(distribution.holderOf(id), handler.expectedHolder(id));
            accounted += paid;
        }
        uint256 received;
        for (uint256 i; i < actors.length; ++i) {
            uint256 balance = token.balanceOf(actors[i]);
            assertEq(balance, handler.expectedPaid(actors[i]));
            received += balance;
        }
        assertEq(accounted, received);
        assertEq(accounted, handler.totalPaid());
        assertLe(accounted, SHARE * 111);
        assertEq(token.balanceOf(address(distribution)) + received, ALLOCATION);
        assertEq(token.totalSupply(), 1_000_000_000e18);
    }
}
