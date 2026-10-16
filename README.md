# Swarmbrain (SWARMBRA)

A brain made of hundreds of AI agents on strangers' computers. Trading real money, in public.

- X: [@swarmbrain](https://x.com/swarmbrain)
- Website: swarmbrain.fun

This repository holds the Swarmbrain ERC-20 token, its tests and the notes a launch operator needs.

## The token

| Item | Value |
| --- | --- |
| Solidity contract | `SwarmbrainToken` (`src/SwarmbrainToken.sol`) |
| `name()` | `Swarmbrain` |
| `symbol()` | `SWARMBRA` |
| `decimals()` | `18` |
| `totalSupply()` | `1_000_000_000 * 10**18` = `1000000000000000000000000000` minor units |
| Constructor arguments | none |
| Minting | once, in the constructor, the whole supply to `msg.sender` (the deployer) |
| Owner / admin | none |
| Transfer rules | plain ERC-20: no fee, no burn, no pause, no blocklist, no hook |

The contract is a self-contained ERC-20 that follows OpenZeppelin v5 semantics and ERC-6093 custom
errors (`ERC20InsufficientBalance`, `ERC20InsufficientAllowance`, `ERC20InvalidReceiver`,
`ERC20InvalidSpender`, `ERC20InvalidSender`, `ERC20InvalidApprover`). It is implemented directly in
`src/` rather than imported so the project has no library to vendor and builds offline with nothing
but the pinned compiler.

Behaviour worth knowing:

- `transfer` and `transferFrom` move exactly the amount asked. Transfers to the zero address revert.
- An allowance of `type(uint256).max` is treated as infinite and is never decremented.
- `approve` overwrites the previous allowance (standard ERC-20; use a zero approval first when
  racing an existing spender matters to you).
- `totalSupply()` is constant for the life of the contract. The only call to `_mint` is in the
  constructor, there is no `burn`, and there is no owner, minter, pauser or upgrade path.
- The runtime contains no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`, and the constructor calls
  no other contract, so it deploys on an empty chain.

## Assumptions

- The deployer is whoever runs the constructor. Under the IMD launch that is the ProjectFactory,
  which receives the full supply and pays it out (10% to the launch's MerkleDistributor, the pool
  share into the Uniswap v4 pool, the remainder to the requester's address). The token does not
  need to know any of those addresses because it treats every holder the same.
- No address is exempt from anything because nothing applies to anyone: there is no fee or
  restriction to be exempt from.
- The brief named no fee, tax, vesting, governance or burn, so none is implemented. Adding one
  later would need a new contract and a new launch; this one is final once deployed.
- The brief left no number open. Supply, decimals, name and symbol are all fixed by the brief and
  written as constants in the contract (`TOTAL_SUPPLY`, `decimals`, `name`, `symbol`).

## Deployment parameters

The launch is performed by IMD's deployer through the ProjectFactory, not by this repository.
Values the manifest step needs, all fixed by this code:

| Manifest field | Value |
| --- | --- |
| `token.contract` | `SwarmbrainToken` |
| `token.name` | `Swarmbrain` |
| `token.symbol` | `SWARMBRA` |
| `token.decimals` | `18` |
| `token.totalSupply` | `1000000000000000000000000000` |
| `token.constructorArgs` | `[]` |
| `contracts` | `[]` (no application contracts) |

Launch-side values the requester chose, listed here for the record and copied by the manifest
step from the job, not from this file: chain Ethereum (chain id 1); pair currency IMD
(`0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`); pool fee 12500 (1.25%); tick spacing 60;
`poolBps` 5000; `initialMarketCapWei` 3888 IMD for the whole supply; `remainderTo`
`0xee2aaa315cf7ed169f93148d30d24af9318dbb66`.

Do not write `launch.json` in this repository. The manifest step writes it after the work is accepted.

Deploying outside the IMD launch (for example on a local Anvil) is a single zero-argument
contract creation. The account that sends the creation transaction receives the whole supply:

```sh
forge create src/SwarmbrainToken.sol:SwarmbrainToken --rpc-url <rpc> --private-key <key>
```

This repository does not hold keys, does not broadcast, and ships no deploy script, because the
constructor has nothing to configure.

## After launch

There is nothing to set. The token has no owner-settable storage, no setter and no external
dependency, so no post-launch configuration step exists and nothing can be left unconfigured.

## Operational responsibilities

- **Holding the supply.** Whoever deploys the token holds all of it until they transfer it. Under
  the IMD launch the factory pays it out in the same transaction; outside that launch, the
  deployer's key is the only thing protecting the supply.
- **No recovery.** There is no admin. Tokens sent to the zero address are refused by the contract,
  but tokens sent to any other wrong address, including the token contract itself, cannot be
  recovered by anyone.
- **Allowances.** Holders are responsible for the allowances they grant, including infinite
  ones to routers and pool managers.
- **Explorer verification.** Verify the source on Etherscan after the launch
  (`forge verify-contract <address> src/SwarmbrainToken.sol:SwarmbrainToken --chain 1`, with the
  same `foundry.toml` settings: solc 0.8.26, optimizer on, 200 runs, `bytecode_hash = "none"`).
  This is the deployer's step, not this repository's.
- **Audit.** The tests below are not a security audit. The contract is small and has no privileged
  paths, but an independent adversarial review before release is still the right practice.

## Build and test

Requirements: Foundry with solc 0.8.26 available offline. No git submodules, no `lib/`, no network.

```sh
forge build
forge test -vvv
forge fmt --check
```

`foundry.toml` pins `solc = "0.8.26"`, `evm_version = "cancun"`, the optimizer at 200 runs and
`bytecode_hash = "none"` so the deployed bytes are reproducible without a metadata hash. Fuzz runs
default to 256; the verifier sets its own seed through `FOUNDRY_FUZZ_SEED`, and the fuzz tests hold
for any input.

### Tests

`test/SwarmbrainToken.t.sol` deploys the token from a pranked factory address and covers:

- metadata, the one-time mint of the whole supply to the deployer, and that a fresh deployment
  from another account mints to that account;
- `transfer` success paths (ordinary, whole balance, zero amount, self, onward transfers) and
  failures (insufficient balance, one wei above balance, zero-address receiver), with exact
  ERC-6093 error data;
- `approve` success (event, overwrite, clear) and the zero-spender failure;
- `transferFrom` success (exact allowance decrement, spending the exact allowance, infinite
  allowance untouched) and failures (no approval, short allowance, short balance despite
  allowance, zero-address receiver);
- that no mint, owner, upgrade, pause, blocklist, freeze, lock, seize or `burnFrom` entry point
  exists, tried from a stranger and from the deployer, and that a holder keeps its balance and can
  still transfer afterwards;
- the launch flows end to end with exact amounts: 10% to a distributor and a whole claim out of
  it, 50% to a pool, a buy and a sell back, and the remainder to the requester, with the supply
  unchanged;
- fuzz tests for conservation of supply, reverting above balance, allowance enforcement, exact
  approvals, and chained transfers.

The tests use a small in-repo cheatcode interface (`test/utils/TestBase.sol`) rather than
forge-std, so the project has no dependency to install. `test/scratch/` is reserved for local
scaffolding and is ignored.

## Layout

```
foundry.toml                 compiler pins and build settings
src/SwarmbrainToken.sol      the token
test/SwarmbrainToken.t.sol   tests
test/utils/TestBase.sol      cheatcode interface and assertion helpers
```
