# FWAIR PFP ABI provenance

The only external NFT calls used by HolderClaim are:

```solidity
function ownerOf(uint256 id) external view returns (address);
function tokenLocks(uint256 tokenId) external view returns (address holder, uint32 betaId);
```

These signatures were checked against the verified contract at Ethereum address `0x29f1cBC8eccD64B0cE777f5Da45c72C47383a620` using both [Sourcify's contract endpoint](https://sourcify.dev/server/v2/contract/1/0x29f1cbc8eccd64b0ce777f5da45c72c47383a620?fields=abi,metadata,sources) and [Blockscout's verified source endpoint](https://eth.blockscout.com/api/v2/smart-contracts/0x29f1cBC8eccD64B0cE777f5Da45c72C47383a620).

Sourcify returned chain ID `1`, match ID `43979931`, creation and runtime status `match`, verified timestamp `2026-08-20T15:36:20Z`, and compiler `0.8.26+commit.8a97fa7a`. The verified contract name is `FWAIRPFPs`; its lock struct has `address holder` followed by `uint32 betaId`. The constructor mints IDs 1–111. The ABI subset is saved in [FWAIRPFP.abi.json](FWAIRPFP.abi.json) so tests and reviewers need no network access.

This check establishes the ABI layout, not a live state snapshot or a mainnet fork test. HolderClaim deliberately reads current ownership/lock information on every claim. Its fixed address and the behavior of that external contract are trust assumptions. The local mock adds test controls for burns and lookup failures to exercise otherwise hard-to-reproduce cases; it is not a deployable replacement for the mainnet PFP.
