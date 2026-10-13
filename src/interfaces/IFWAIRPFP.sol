// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Read-only subset of the Ethereum FWAIRPFPs ABI.
interface IFWAIRPFP {
    function ownerOf(uint256 id) external view returns (address);

    function tokenLocks(uint256 id) external view returns (address holder, uint32 betaId);
}
