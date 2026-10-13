# Launch economics and manifest checklist

The previous attempt of this project stopped at the manifest step: the job's paid economics said
`poolBps = 8800` with the remainder routed to a wallet, while the brief requires 10% of the supply in
the PIC/FWA pool and 800,000,000 PIC (80%) in HolderClaim. The requester chose **Option 1**: change
the economics to `poolBps = 1000` and route the whole remainder to HolderClaim in the launch
transaction. This document records what that means for the manifest, the contracts and the people
running the launch. Nothing here deploys anything; the repository still supplies no `launch.json`.

## Assumptions

- PIC supply is 1,000,000,000 with 18 decimals, minted once to the launch factory by `PICToken`'s
  constructor. `LaunchEconomics.TOTAL_SUPPLY` equals `PICToken.INITIAL_SUPPLY`; a test pins them.
- The launch factory, after deploying the token and HolderClaim, holds the entire supply and performs
  the split in the same transaction: pool share, swarm share, then the remainder.
- Shares are expressed in basis points of the total supply and round down. With 10,000-divisible
  amounts there is no rounding here; if there were, the remainder would absorb it so the factory
  keeps nothing.
- The swarm share stays 10%. The FWA pair, `initialMarketCapWei` (2,000,000 FWA), the 1.25% pool fee
  and tick spacing 60 are unchanged from the earlier brief.
- HolderClaim pays at most `SHARE * 111 = ALLOCATION - 23` base units in total; the 23 base units of
  division dust are locked forever, as are burned and unclaimed shares.

## Manifest values

| Field | Value | Where it comes from |
| --- | --- | --- |
| `poolBps` | `1000` | `LaunchEconomics.POOL_BPS` |
| swarm share | 10% (`LaunchEconomics.SWARM_BPS = 1000`) | unchanged from the brief |
| `remainderTo` | the deployed **`HolderClaim`**, resolved by Solidity name | brief: "the launch sends the 80% to it by that name" |
| remainder amount | `800000000000000000000000000` base units (800,000,000 PIC) | `LaunchEconomics.HOLDER_CLAIM_ALLOCATION` = `HolderClaim.ALLOCATION` |
| `initialMarketCapWei` | `2000000000000000000000000` FWA base units | unchanged |
| pair | FWA `0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845` | unchanged |
| HolderClaim constructor | `token_ = $token` | the PIC address the same launch deploys |
| PICToken constructor | none | |

The wallet that the earlier economics named as `remainderTo` must not appear in the new manifest. It
receives no PIC. If an operator wants that wallet to hold PIC, it has to buy it from the pool like
anyone else.

## What the contracts enforce and what they cannot

The contracts cannot force the factory to send them anything: HolderClaim has no funding function,
no owner and no recovery path, by the brief. What they do provide:

- `HolderClaim.ALLOCATION` is the number the manifest step must match, read straight from
  `LaunchEconomics`, so a reviewer can compare the launch transfer against the artifact.
- `HolderClaim.fundingShortfall()` returns how many base units the balance is short of every unpaid
  share, and `isFunded()` is true when that is zero. Right after a correct launch `isFunded()` is
  true. If the pool took 88% it reads a shortfall of about 780,000,000 PIC; if the remainder went to
  a wallet it reads the full 800,000,000 PIC less 23.
- Vesting starts at HolderClaim's construction, inside the launch transaction. An underfunded
  HolderClaim keeps vesting; claims above its balance revert as a whole and succeed once someone
  deposits the missing PIC. A misrouted remainder is therefore repairable by whoever received it
  transferring it on, but nothing in the contracts can compel that.

## Operational responsibilities

Before launch, the launch operator:

1. Confirms the manifest carries `poolBps = 1000`, the swarm share and `remainderTo = HolderClaim`
   (by name), and that `initialMarketCapWei` and the FWA pair are unchanged.
2. Confirms the HolderClaim artifact is `src/HolderClaim.sol:HolderClaim` built with the pinned
   compiler, and that its constructor argument is `$token`.
3. Simulates the launch transaction and checks the three balances: pool 100,000,000 PIC, swarm
   100,000,000 PIC, HolderClaim 800,000,000 PIC, factory 0.

After launch, the operator or any holder:

1. Reads `HolderClaim.isFunded()` and expects `true`; reads `token()` and expects the launched PIC.
2. Reads `START()` and expects the launch block's timestamp; the full SHARE per ID is claimable from
   `START + 20 days`.
3. Verifies source on the explorer with the pinned settings (0.8.26, Cancun, optimizer 200 runs,
   `bytecode_hash = "none"`).

Nothing needs to be configured afterward: there are no setters, no keeper and no oracle. FWA fee
payouts owed to the launch factory depend on FWA's owner registering the factory as a distributor;
that is the launch network's concern and does not touch PIC or HolderClaim.

## Tests

`test/LaunchEconomics.t.sol` simulates the launch transaction with a stand-in factory that takes the
manifest economics as an argument and resolves a zero `remainderTo` to the deployed HolderClaim, as
the manifest step does. It checks the 10/10/80 balances and `isFunded()` after the correct launch,
that every share can be paid, and three failure modes: the earlier `poolBps = 8800` economics, a
remainder routed to a wallet, and a share split above 100%. The stand-in does not create a Uniswap
pool; the launch network's own verifier owns the pool checks.
