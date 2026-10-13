// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @dev Test-only PFP at the fixed mainnet address via vm.etch; never deployed for the launch.
contract MockPFP is ERC721 {
    struct TokenLock {
        address holder;
        uint32 betaId;
    }

    mapping(uint256 => TokenLock) private locks;
    bool public initialized;
    bool public failLockLookup;

    error LockLookupFailed();

    constructor() ERC721("FWAIR PFPs mock", "FWAIR") {}

    function initialize(address holder) external {
        require(!initialized, "already initialized");
        initialized = true;
        for (uint256 id = 1; id <= 111; ++id) {
            _mint(holder, id);
        }
    }

    function tokenLocks(uint256 id) external view returns (address holder, uint32 betaId) {
        if (failLockLookup) revert LockLookupFailed();
        TokenLock memory locked = locks[id];
        return (locked.holder, locked.betaId);
    }

    function lock(uint256 id, uint32 betaId) external {
        require(ownerOf(id) == msg.sender, "not owner");
        locks[id] = TokenLock(msg.sender, betaId);
        _transfer(msg.sender, address(this), id);
    }

    function unlock(uint256 id) external {
        require(locks[id].holder == msg.sender, "not holder");
        delete locks[id];
        _transfer(address(this), msg.sender, id);
    }

    function setLock(uint256 id, address holder, uint32 betaId) external {
        locks[id] = TokenLock(holder, betaId);
    }

    function setFailLockLookup(bool value) external {
        failLockLookup = value;
    }

    function burn(uint256 id) external {
        _burn(id);
    }
}
