# Tock

**Scheduled transactions for [Arc](https://www.arc.io), paid in USDC.** Schedule a payment or any contract call. When it falls due, anyone can run it — and is refunded the gas, plus a tip, from the owner's prepaid balance.

No server to keep alive, no keeper token, no price oracle, no admin keys.

- **App:** _added at deployment_
- **Contract (Arc mainnet, chain 5042):** _added at deployment_

## Why

Smart contracts can't wake themselves up. Anything recurring — rent, payroll, a harvest, a settlement — needs someone to send a transaction on time. The hosted services that used to do this have been closing or consolidating: Gelato announced the shutdown of Web3 Functions for March 31, 2026, and Chainlink [deprecated Automation](https://docs.chain.link/cre/reference/cla-migration-ts) on July 31, 2026 in favour of CRE.

A permissionless scheduler needs one hard thing: paying whoever executes fairly. Elsewhere that means a keeper token or a price feed, because the executor spends one asset on gas and is repaid in another. **On Arc, gas is USDC and the native balance is dollars**, so the whole fee path collapses:

```solidity
// the owner's deposit is msg.value; the refund is a plain native transfer
uint256 fee = (gasStart - gasleft() + overhead) * block.basefee + j.tip;
if (fee > maxFee) fee = maxFee;
balanceOf[j.owner] -= fee;
_pay(executor, fee);
```

No token contract is touched and no conversion happens. Measured with real transactions on a mainnet fork, a scheduled payment costs about 100,000 gas to run — roughly **$0.002** — and the executor gets back 100–109% of what it spent (`keeper/calibrate.mjs` reproduces the numbers).

## How it works

```
owner    ── createJob(target, data, value, interval, gasLimit, maxFee, tip) ──▶ job #n
owner    ── deposit()  (native USDC)  ──▶ gas balance
owner    ── send USDC to their Agent ──▶ what scheduled payments are paid from

when due, anyone:
executor ── run(job) ─▶ Tock ─▶ owner's Agent ─▶ target.call{value}(data)
                        └─ pays executor: gas × base fee + tip, capped at maxFee
```

Three accounts, kept apart on purpose:

- **Gas balance** — USDC deposited into Tock to pay executors. Spent only on the owner's own jobs, never more than a job's cap per run, withdrawable at any time.
- **Agent** — a small contract created for each owner with their first job. Every job runs *from* it, so the target sees the owner's Agent as `msg.sender`, never Tock and never another user. Scheduled payments leave from its balance. Only Tock (for that owner's jobs) and the owner can use it.
- **Executor** — anyone.

The Agent is what makes this safe on Arc in particular. USDC's ERC-20 interface moves the *caller's native balance*, and Tock holds everyone's gas money natively — so if jobs ran from Tock itself, a job calling `USDC.transfer` or `USDC.approve` could reach all of it. Because jobs run from the owner's Agent, a job can only spend what that Agent holds. There is a test for exactly this.

Guard rails:

- **A job gets its full gas or the run reverts.** An executor cannot starve the call to make it fail and still collect a fee.
- **An executor is never out of pocket.** If the fee cap cannot cover a run that burns its whole gas limit at the current base fee, the job waits. `runnable()` lists only jobs that are safe to run, and `worstCaseGas()` gives a gas limit that is always enough — so a target that behaves differently when simulated cannot make a keeper burn gas.
- **Refunds use `block.basefee`, not `tx.gasprice`.** An executor that overbids pays the difference itself.
- **The per-transaction overhead is refunded once per transaction**, so looping single runs gains nothing.
- **A failing call still pays the executor**, who did the work — but three failures in a row pause the job, so a broken target or an empty Agent cannot drain the gas balance.
- **Late runs do not burst.** The next run is always at least a full interval after the last.
- **No owner, no fee switch, no upgrade path.** Tock takes no fee.

## Repository

```
contracts/   Tock.sol (Tock + Agent), Foundry tests run against an Arc mainnet fork, deploy script
web/         Static front end — Vite, TypeScript, viem. No backend, no indexer.
keeper/      A small bot that runs due jobs, plus the calibration script
```

## Run it

**Contracts.** Needs [Arc Foundry](https://docs.arc.io/arc/tutorials/install-arc-foundry), which emulates Arc's native-USDC precompiles.

```sh
cd contracts
arc-forge test          # 39 tests, forks Arc mainnet over the public RPC
```

**Web.**

```sh
cd web
npm install
VITE_TOCK=0x… npm run dev
npm run build           # static site in web/dist
```

**Keeper.**

```sh
cd keeper
npm install
PRIVATE_KEY=0x… TOCK=0x… npm run keeper
```

## Notes for Arc builders

- A plain `eth_call` reports `block.basefee` as zero. Views that depend on the base fee take it as an argument (`runnable(from, count, baseFee)`); pass the latest block's value.
- The public RPCs return only about 1,000 blocks of logs per query, so the app reads everything from contract state and views; it never scans events.
- The EasyPrivacy filter list contains `||arc.io^$third-party`, which blocks browser requests to every official `*.arc.io` RPC endpoint for visitors using Brave Shields or uBlock Origin. The app falls back to endpoints on other domains.

## Status

An early proof of concept. The contract went through one adversarial review pass, whose findings are fixed and kept as regression tests in `contracts/test/Review.t.sol`. **It has not been professionally audited.** Use small amounts.

Known limits: jobs are executed in the order executors choose, with no ordering or exact-time guarantee; a job's calldata is fixed when it is created and limited to 1 KB; funds sent to the Tock contract by mistake cannot be recovered; and anything a job's target does with the Agent as caller is the owner's responsibility.

Sister project: [Standing](https://github.com/ferrousowl/standing), recurring pull payments (subscriptions) built on the same refund idea.

## License

MIT
