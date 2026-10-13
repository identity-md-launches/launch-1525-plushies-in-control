// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title LaunchEconomics
/// @notice The PIC launch split, fixed in source so the manifest, the contracts and the tests agree.
/// @dev The launch factory holds the whole supply after deploying PICToken, seeds the PIC/FWA pool with
/// `POOL_BPS`, sends `SWARM_BPS` to the swarm distributor and routes the entire remainder to HolderClaim in
/// the same transaction. Every function is internal, so no link placeholder is left in any bytecode.
library LaunchEconomics {
    uint256 internal constant BPS = 10_000;

    /// @dev Equal to PICToken.INITIAL_SUPPLY; the test suite pins the two together.
    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000 * 1e18;

    /// @notice Manifest `poolBps`: 10% of the supply seeds the PIC/FWA pool.
    uint256 internal constant POOL_BPS = 1000;
    /// @notice Share sent to the launch swarm distributor: 10%.
    uint256 internal constant SWARM_BPS = 1000;
    /// @notice Everything that is left, 80%, is the manifest remainder and goes to HolderClaim.
    uint256 internal constant HOLDER_CLAIM_BPS = BPS - POOL_BPS - SWARM_BPS;

    uint256 internal constant POOL_ALLOCATION = TOTAL_SUPPLY * POOL_BPS / BPS;
    uint256 internal constant SWARM_ALLOCATION = TOTAL_SUPPLY * SWARM_BPS / BPS;
    /// @notice 800,000,000 PIC in base units; HolderClaim.ALLOCATION reads this value.
    uint256 internal constant HOLDER_CLAIM_ALLOCATION = TOTAL_SUPPLY - POOL_ALLOCATION - SWARM_ALLOCATION;

    error SharesExceedSupply(uint256 poolBps, uint256 swarmBps);

    /// @notice Split a supply the way the launch factory does: pool and swarm shares first, remainder last.
    /// @dev Rounds each share down and gives every rounding wei to the remainder, so nothing is left behind.
    function split(uint256 supply, uint256 poolBps, uint256 swarmBps)
        internal
        pure
        returns (uint256 pool, uint256 swarm, uint256 remainder)
    {
        if (poolBps + swarmBps > BPS) revert SharesExceedSupply(poolBps, swarmBps);
        pool = supply * poolBps / BPS;
        swarm = supply * swarmBps / BPS;
        remainder = supply - pool - swarm;
    }

    /// @notice The split the PIC launch transaction must perform on the full supply.
    function launchSplit() internal pure returns (uint256 pool, uint256 swarm, uint256 remainder) {
        return split(TOTAL_SUPPLY, POOL_BPS, SWARM_BPS);
    }
}
