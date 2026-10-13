# Plushies In Control (PIC)

Ethereum mainnet ERC-20 and an immutable vesting claim for FWAIR PFP holders. There is no website.

## Contracts

| Artifact | Constructor | Purpose |
| --- | --- | --- |
| `src/PICToken.sol:PICToken` | No arguments | `Plushies In Control`, `PIC`, 18 decimals; mints exactly 1,000,000,000 PIC to `msg.sender` once |
| `src/HolderClaim.sol:HolderClaim` | `address token_` = launch `$token` | Pays vested PIC to the current holder of each eligible NFT ID |

PIC is a standard ERC-20 using vendored OpenZeppelin Contracts v5.1.0. Its supply in base units is `1000000000000000000000000000`. It has no fees, later minting, public burning, owner, privileged transfer restrictions, or upgrade mechanism. Ordinary transfers, allowances, and `transferFrom` work normally.

HolderClaim has no owner, administration, upgrade, pause, recovery, or withdrawal function. Its sole payout operation is `claim`, which transfers PIC to the calling NFT holder. It never transfers or burns an NFT and never grants token allowances. Other assets sent to it cannot be recovered.

## Launch parameters and responsibilities

Target Ethereum mainnet, chain ID **1**. Deploy the token first, then **`HolderClaim`** with the deployed PIC address as its sole constructor argument. The application must be recorded under that exact Solidity name so the launch can resolve its address. The token artifact name is **`PICToken`**. Both constructors make no external calls; HolderClaim rejects a zero token address but does not require token or PFP code during construction.

The launch factory initially holds the entire PIC supply. In the same launch transaction, it must distribute it as follows:

| Destination | Share of total supply | PIC | Base units |
| --- | --- | --- | --- |
| PIC/FWA pool | 10% (`poolBps = 1000`) | 100,000,000 | `100000000000000000000000000` |
| Launch swarm distributor | 10% | 100,000,000 | `100000000000000000000000000` |
| Deployed `HolderClaim` | 80% | 800,000,000 | `800000000000000000000000000` |

The task's allocation above is authoritative. HolderClaim's constructor does not take the allocation from the factory: the launch must send it explicitly. The application starts vesting immediately at construction, so delaying funding does not delay vesting. Underfunded payouts revert completely and can be retried after funding; there is no partial payout or funding administrator.

The pair is FWA at `0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845` (18 decimals). The supplied launch policy specifies pool fee `12500` (1.25%), tick spacing `60`, and opening market capitalization `2000000000000000000000000` FWA base units (2,000,000 FWA). The reference `initialPrice` is `79228162514264337593543950336`; the launch system derives the actual opening price from capitalization, supply, and currency ordering. These pool operations belong to the launch system, not either contract here.

The separate manifest step must resolve the remainder recipient to the deployed **HolderClaim**, and pass `$token` to its constructor. This repository intentionally supplies no `launch.json`, signing key, broadcasting script, pool implementation, or swarm distributor. The launch network supplies those integration pieces and performs deployment after acceptance.

Before launch, the launch operator must verify the chosen artifacts and constructor arguments, the mainnet PFP address and ABI, the exact allocation, and that the remainder routing funds HolderClaim atomically. After launch, verify source and inspect `token()`, `START()`, the fixed constants, and the 800,000,000 PIC funding transfer. No contract configuration or keeper is needed afterward. The supplied FWA reference says FWA fee payouts from the launch factory require the FWA owner to register that factory as a distributor; otherwise those fees remain owed in the launch system. HolderClaim handles PIC only.

## Vesting and ownership

- `PFP = 0x29f1cBC8eccD64B0cE777f5Da45c72C47383a620` (FWAIR PFPs).
- Eligible token IDs are **1 through 111 inclusive**.
- `SHARE = floor(800000000000000000000000000 / 111)` = **`7207207207207207207207207` PIC base units** per ID.
- `START` is HolderClaim's constructor timestamp; `VESTING = 20 days = 1,728,000 seconds`.
- `vested(id) = floor(SHARE * min(block.timestamp - START, VESTING) / VESTING)`.

Vesting is continuous, approximately 5% per day, with integer rounding down in base units. There is no daily claim restriction or cliff. The full SHARE is available at exactly 20 days and stays available indefinitely. Claims pay the difference between cumulative vesting and cumulative claimed amounts, so frequent claims do not lose additional rounding amounts.

`holderOf(id)` first reads the PFP's `ownerOf(id)`. If the owner is the PFP contract itself, it reads the `holder` from `tokenLocks(id)`, whose verified return types are `(address holder, uint32 betaId)`. Otherwise it uses the actual ERC-721 owner. NFT approvals and operators do not grant claim rights. A stale lock record is ignored when the NFT is outside the PFP contract. A revert from `ownerOf` means no holder; a failing lock lookup reverts rather than paying a different account. See [the ABI provenance](docs/PFP-ABI.md).

Claims are attached to IDs, never to a wallet's historic holdings. A new holder receives all vesting left unclaimed for the ID, including vesting accrued before purchase. Previously paid amounts stay recorded after any sale, lock, unlock, or burn. For example, if Alice claims half of an ID's SHARE on day 10 and sells it to Bob, Bob can receive only the remaining half by day 20. If Alice claimed nothing, Bob can claim the entire SHARE at day 20.

Burned IDs have no claimant. Their unpaid amounts stay locked, as do unclaimed amounts, unsolicited deposits, and the **23 base units** left over when the allocation is divided by 111. Nobody can sweep these funds. There is no expiry; a living ID's legitimate holder can still claim its unclaimed amount after day 20.

## Calls and view semantics

All amounts below are PIC base units.

| Function | Behavior |
| --- | --- |
| `claimed(id)` | Cumulative amount paid for that ID. Public mapping; unset and invalid IDs read as zero. |
| `vested(id)` | Total cumulative vesting, including previously paid amounts; does not check whether the NFT is alive. |
| `holderOf(id)` | Current direct/lock holder, or the zero address for a burned ID or an empty lock record. |
| `claimable(id)` | Exactly `vested(id) - claimed(id)`. A burned ID can have a positive accounting value which nobody can receive. |
| `claimableFor(account, ids)` | Sum for distinct supplied IDs currently held by `account`. Other holders and burned IDs contribute zero. A zero account always has zero entitlement. |
| `claim(ids)` | Requires the caller to hold every supplied ID. Updates per-ID accounting and sends the aggregate in one token transfer; returns the aggregate. |

The task's final sentence about `claimableFor` was truncated. This implementation interprets it as the total above, deduplicating IDs so the preview cannot count the same entitlement twice. All ID-taking views except the raw `claimed` mapping reject IDs outside 1–111 with `InvalidId(id)`. `claimableFor` filters non-held IDs; `claim` rejects them with `NotHolder(id)`, even if nothing remains to pay. Thus a preview over a mixed-owner list is not permission to submit that entire list to `claim`.

Empty claims and fully paid batches succeed with a zero result and no token transfer. Duplicates pay once. A later invalid or unauthorized ID, a failed PFP lock lookup, or a failed token transfer reverts the entire batch. A reentrancy guard protects `claim`; all accounting is updated before the final `SafeERC20` transfer. Each paid ID emits `Claimed(account, id, amount)`.

Use an Ethereum contract interaction tool or wallet to read the views and call `claim` with an array such as `[1, 7, 111]` from the current holder's account. No PIC allowance or NFT approval is needed. A contract holding an NFT must itself be able to call `claim`; HolderClaim does not let a different account redirect its payout. Read a fresh preview near submission because the holder, vesting, or prior claims may change before inclusion.

## Build and test offline

Requires Foundry and an installed Solidity **0.8.26** compiler. Dependencies are ordinary vendored files in `lib/`, with upstream licenses and version/hash records. No dependency download, RPC, environment variables, FFI, filesystem cheatcodes, or submodules are needed by the tests.

```sh
forge build
forge test
forge fmt --check
```

`foundry.toml` pins Solidity 0.8.26, Cancun, optimizer runs 200, and `bytecode_hash = "none"`. Production bytecode has no linked libraries. Source tests cover launch allocation, ERC-20 failure paths, per-second/end-point vesting, sales, approvals, escrow locks, burns, duplicate batches, failed payment rollback, no-return tokens, and callback reentrancy. Fuzz tests cover arithmetic and duplicate lists; a stateful invariant checks an independent ownership/payment model and conservation across claims, transfers, locks, burns, and time advances.

PFP behavior is mocked at its mainnet address, with the verified ABI. The allocation harness tests PIC transfers in one local transaction; it does not implement or claim to test a live Uniswap pool. The supplied protected launch harness depends on the launch verifier's factory support files and manifest environment and remains an input to that independent stage. Read [the security review notes](docs/SECURITY.md) for scope and assumptions.
