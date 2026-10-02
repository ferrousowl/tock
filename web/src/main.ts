import {
  encodeFunctionData,
  isAddress,
  parseAbi,
  parseEther,
  toFunctionSelector,
  type Abi,
  type Address,
  type Hex,
} from "viem";
import { DEPLOYED, TOCK, agentAbi, arc, client, getJobs, range, tockAbi, type Job } from "./chain";
import { date, esc, every, explain, relative, short, usd } from "./format";
import { connect, disconnect, onWallet, restore, send, state, transfer } from "./wallet";
import "./style.css";

const app = document.querySelector<HTMLElement>("#app")!;
const tock = { address: TOCK, abi: tockAbi } as const;
const explorer = arc.blockExplorers.default.url;

/** Gas a plain scheduled payment costs to run, measured on a mainnet fork. For estimates only. */
const TYPICAL_RUN_GAS = 100_000n;

/** Chain time in seconds. Due dates are judged by the chain's clock, not the visitor's. */
const chainNow = async () => Number((await client.getBlock()).timestamp);

// ───────────────────────────── shell ─────────────────────────────

function toast(message: string, kind: "ok" | "err" = "ok") {
  document.querySelector(".toast")?.remove();
  const el = document.createElement("div");
  el.className = `toast ${kind}`;
  el.setAttribute("role", "status");
  el.textContent = message;
  document.body.append(el);
  setTimeout(() => el.remove(), 6000);
}

/** Run a wallet action from a button: disable it, show progress, surface failures as a toast. */
async function act(button: HTMLButtonElement, busyLabel: string, fn: () => Promise<void>) {
  const label = button.textContent;
  button.disabled = true;
  button.textContent = busyLabel;
  try {
    await fn();
  } catch (err) {
    toast(explain(err), "err");
  } finally {
    button.disabled = false;
    button.textContent = label;
  }
}

function header(): string {
  const account = state.address
    ? `<button class="chip" data-action="disconnect" title="Disconnect">${short(state.address)}</button>`
    : `<button class="btn small" data-action="connect">Connect wallet</button>`;
  const link = (href: string, text: string) =>
    `<a href="${href}" class="${location.hash === href || (href === "#/" && !location.hash) ? "on" : ""}">${text}</a>`;
  return `
    <header class="top">
      <a class="brand" href="#/"><span class="mark" aria-hidden="true"></span>Tock</a>
      <nav>${link("#/new", "Schedule")}${link("#/jobs", "My jobs")}${link("#/run", "Executors")}${link("#/how", "How it works")}</nav>
      ${account}
    </header>`;
}

const footer = () => `
  <footer>
    <span>Scheduled transactions on <a href="https://www.arc.io" target="_blank" rel="noopener">Arc</a> · open source (MIT) · no admin keys</span>
    ${DEPLOYED ? `<a href="${explorer}/address/${TOCK}" target="_blank" rel="noopener">Contract ${short(TOCK)}</a>` : ""}
  </footer>`;

// ───────────────────────── describing jobs ────────────────────────

const KNOWN: Record<string, string> = Object.fromEntries(
  ["transfer(address,uint256)", "executeBatch(uint256[])", "runBatch(uint256[])", "claim()", "harvest()", "poke()"].map(
    (sig) => [toFunctionSelector(sig), sig.split("(")[0]],
  ),
);

/** A one-line, human description of what a job does when it runs. */
function describe(j: Job): string {
  if (j.data === "0x" && j.value > 0n) return `Pay ${usd(j.value)} to ${short(j.target)}`;
  const fn = KNOWN[j.data.slice(0, 10)] ?? j.data.slice(0, 10);
  return `Call ${esc(fn)} on ${short(j.target)}${j.value > 0n ? ` with ${usd(j.value)}` : ""}`;
}

function status(j: Job, now: number): string {
  if (j.interval === 0) return `<span class="tag">Ended</span>`;
  if (!j.active) return `<span class="tag warn">${j.failures >= 3 ? "Paused after 3 failures" : "Paused"}</span>`;
  if (j.nextRun <= now) return `<span class="tag ok">Due now</span>`;
  return `<span class="tag ok">Active</span>`;
}

// ───────────────────────────── views ─────────────────────────────

async function home(): Promise<string> {
  let stats = "";
  if (DEPLOYED) {
    const count = await client.readContract({ ...tock, functionName: "jobCount" });
    const jobs = await getJobs(range(count));
    stats = `
      <dl class="stats">
        <div><dt>Jobs scheduled</dt><dd>${count}</dd></div>
        <div><dt>Active now</dt><dd>${jobs.filter((j) => j.active).length}</dd></div>
        <div><dt>Runs executed</dt><dd>${jobs.reduce((n, j) => n + j.runs, 0)}</dd></div>
      </dl>`;
  }
  return `
    <section class="hero">
      <p class="eyebrow">Scheduled transactions for Arc</p>
      <h1>Set it once. It runs on time, and pays its own way.</h1>
      <p class="lede">Schedule a payment or any contract call. When it falls due, anyone can run it — and is paid
      back the gas from your prepaid balance, in USDC. No server to keep alive, no keeper token, no subscription
      to an automation service.</p>
      <div class="row">
        <a class="btn" href="#/new">Schedule something</a>
        <a class="btn ghost" href="#/run">Earn by running jobs</a>
      </div>
      ${stats}
    </section>

    <section class="grid3">
      <article>
        <h3>Pay rent, payroll, an allowance</h3>
        <p>Send USDC to someone every week or month. Fund your agent account once and the payments leave on
        schedule. A run costs about $0.002.</p>
      </article>
      <article>
        <h3>Keep a protocol ticking</h3>
        <p>Harvest, rebalance, settle, poke an oracle. If a function is safe for anyone to call, Tock can call it
        on a timer, from an account that is yours alone.</p>
      </article>
      <article>
        <h3>Costs you can read</h3>
        <p>You set the most a run may cost. Executors are refunded real gas at the base fee plus your tip, never
        more than your cap. A job that fails three times pauses itself.</p>
      </article>
    </section>

    <section class="why">
      <h2>Why this is simple on Arc</h2>
      <p>Automation networks elsewhere need their own token or a price feed, because the keeper pays gas in one
      asset and is repaid in another. On Arc gas <em>is</em> USDC, and the native balance is dollars: your deposit
      is <code>msg.value</code>, the executor's cost is <code>gasUsed × basefee</code>, and the refund is a plain
      transfer. The whole fee path uses no token contract and no oracle.</p>
    </section>`;
}

let tab: "payment" | "call" = "payment";

function schedule(): string {
  const intervals = `
    <option value="3600">hour</option>
    <option value="86400">day</option>
    <option value="604800" selected>week</option>
    <option value="2592000">month (30 days)</option>`;
  const fees = `
    <details>
      <summary>Fees and limits</summary>
      <p class="muted small">Whoever runs your job is refunded its gas (about $0.002 for a payment) plus the tip.
      The cap is the most one run can ever cost you; if network fees rise above it, the job waits.</p>
      <div class="split">
        <label>Tip per run (USDC)<input name="tip" inputmode="decimal" value="0.001"></label>
        <label>Most a run may cost (USDC)<input name="maxFee" inputmode="decimal" value="0.02"></label>
      </div>
      <div class="split">
        <label>Gas for the call<input name="gasLimit" inputmode="numeric" value="${tab === "payment" ? 60000 : 200000}"></label>
        <label>Stop after (runs, blank = never)<input name="maxRuns" inputmode="numeric" placeholder="never"></label>
      </div>
    </details>`;
  const body =
    tab === "payment"
      ? `
        <label>Send to<input name="to" required placeholder="0x…" autocomplete="off" spellcheck="false"></label>
        <div class="split">
          <label>Amount (USDC)<input name="amount" required inputmode="decimal" placeholder="25.00"></label>
          <label>Every<select name="interval">${intervals}</select></label>
        </div>
        <label>Label<input name="name" maxlength="64" placeholder="Rent" autocomplete="off"></label>
        <label>Fund now for this many payments
          <select name="prefund"><option value="0">none — I'll fund it later</option><option value="1">1</option><option value="4" selected>4</option><option value="12">12</option></select>
        </label>`
      : `
        <label>Contract to call<input name="target" required placeholder="0x…" autocomplete="off" spellcheck="false"></label>
        <label>Function<input name="signature" required placeholder="harvest() or executeBatch(uint256[])" autocomplete="off" spellcheck="false"></label>
        <label>Arguments, as a JSON array<input name="args" placeholder='[] or [["0","1"]]' autocomplete="off" spellcheck="false"></label>
        <div class="split">
          <label>USDC to send with it<input name="amount" inputmode="decimal" value="0"></label>
          <label>Every<select name="interval">${intervals}</select></label>
        </div>
        <label>Label<input name="name" maxlength="64" placeholder="Nightly harvest" autocomplete="off"></label>`;
  return `
    <section class="narrow">
      <h1>Schedule</h1>
      <p class="muted">Jobs run from your own agent account, created with your first job. Only you and your jobs can use it.</p>
      <div class="tabs">
        <button class="${tab === "payment" ? "on" : ""}" data-action="tab" data-tab="payment">A recurring payment</button>
        <button class="${tab === "call" ? "on" : ""}" data-action="tab" data-tab="call">A contract call</button>
      </div>
      <form id="job-form" class="card">
        ${body}
        <label>Add to your gas balance (USDC)<input name="deposit" inputmode="decimal" value="0.25"></label>
        ${fees}
        <button class="btn" type="submit">${state.address ? "Schedule it" : "Connect wallet to schedule"}</button>
      </form>
    </section>`;
}

async function myJobs(): Promise<string> {
  if (!state.address) {
    return `<section class="narrow center"><h1>My jobs</h1><p class="muted">Connect a wallet to see your jobs,
      your gas balance and your agent account.</p><button class="btn" data-action="connect">Connect wallet</button></section>`;
  }
  const me = state.address;
  const [ids, gas, agent, predicted, now] = await Promise.all([
    client.readContract({ ...tock, functionName: "jobsOf", args: [me] }),
    client.readContract({ ...tock, functionName: "balanceOf", args: [me] }),
    client.readContract({ ...tock, functionName: "agentOf", args: [me] }),
    client.readContract({ ...tock, functionName: "predictAgent", args: [me] }),
    chainNow(),
  ]);
  const jobs = await getJobs([...ids]);
  const agentBalance = await client.getBalance({ address: predicted });
  const hasAgent = !/^0x0+$/.test(agent);

  const rows = jobs
    .slice()
    .reverse()
    .map((j) => {
      const ended = j.interval === 0;
      const actions = ended
        ? ""
        : `${j.active ? `<button class="chip" data-action="pause" data-id="${j.id}">Pause</button>` : `<button class="chip" data-action="resume" data-id="${j.id}">Resume</button>`}
           <button class="chip danger" data-action="cancel" data-id="${j.id}">End</button>`;
      return `
        <tr>
          <td><strong>${esc(j.name || `Job #${j.id}`)}</strong><span class="what muted small">${describe(j)}</span></td>
          <td>${ended ? "—" : every(j.interval)}</td>
          <td>${status(j, now)}</td>
          <td>${j.active ? `${relative(j.nextRun, now)}<br><span class="muted small">${date(j.nextRun)}</span>` : "—"}</td>
          <td>${j.runs}${j.maxRuns ? ` / ${j.maxRuns}` : ""}${j.failures ? `<br><span class="muted small">${j.failures} failed in a row</span>` : ""}</td>
          <td>${actions}</td>
        </tr>`;
    })
    .join("");

  // What the scheduled payments will draw from the agent on their next run.
  const upcoming = jobs.filter((j) => j.active).reduce((n, j) => n + j.value, 0n);
  const short_ = hasAgent && upcoming > agentBalance;

  return `
    <section>
      <h1>My jobs</h1>
      <div class="balances">
        <div class="card">
          <p class="eyebrow">Gas balance</p>
          <p class="figure">${usd(gas)}</p>
          <p class="muted small">Pays executors. Enough for about ${gas / (TYPICAL_RUN_GAS * 20_000_000_000n + parseEther("0.001"))} runs at today's fees.</p>
          <div class="inline">
            <input id="gas-amount" inputmode="decimal" placeholder="0.25" aria-label="Amount in USDC">
            <button class="chip" data-action="deposit">Add</button>
            <button class="chip" data-action="withdraw">Withdraw</button>
          </div>
        </div>
        <div class="card">
          <p class="eyebrow">Agent account</p>
          <p class="figure">${usd(agentBalance)}</p>
          <p class="muted small">${hasAgent ? "Your scheduled payments are sent from here." : "Created with your first job."}
            <a href="${explorer}/address/${predicted}" target="_blank" rel="noopener">${short(predicted)}</a></p>
          <div class="inline">
            <input id="agent-amount" inputmode="decimal" placeholder="10.00" aria-label="Amount in USDC">
            <button class="chip" data-action="fund-agent" data-agent="${predicted}">Add</button>
            ${hasAgent ? `<button class="chip" data-action="drain-agent" data-agent="${agent}">Withdraw</button>` : ""}
          </div>
        </div>
      </div>
      ${short_ ? `<p class="notice warn">Your active payments need ${usd(upcoming)} per round and the agent holds ${usd(agentBalance)}. A payment that can't be made counts as a failure; three in a row pause the job.</p>` : ""}
      <h2>Jobs</h2>
      ${
        rows
          ? `<div class="scroll"><table><thead><tr><th>Job</th><th>Every</th><th>Status</th><th>Next run</th><th>Runs</th><th></th></tr></thead><tbody>${rows}</tbody></table></div>`
          : `<p class="empty">Nothing scheduled yet. <a href="#/new">Schedule something</a>.</p>`
      }
    </section>`;
}

async function executors(): Promise<string> {
  const [total, block] = await Promise.all([client.readContract({ ...tock, functionName: "jobCount" }), client.getBlock()]);
  const now = Number(block.timestamp);
  // The base fee is passed in: a read-only call on Arc sees block.basefee as zero.
  const baseFee = block.baseFeePerGas ?? 20_000_000_000n;
  const ids = await client.readContract({ ...tock, functionName: "runnable", args: [0n, total, baseFee] });
  const jobs = await getJobs([...ids]);

  const rows = jobs
    .map((j) => {
      const refund = TYPICAL_RUN_GAS * baseFee + j.tip;
      return `
        <tr>
          <td>#${j.id}</td>
          <td><strong>${esc(j.name || "Untitled")}</strong><span class="what muted small">${describe(j)}</span></td>
          <td>${relative(j.nextRun, now)}</td>
          <td>${usd(j.tip)}</td>
          <td>${usd(refund < j.maxFee ? refund : j.maxFee)}</td>
        </tr>`;
    })
    .join("");

  const body = jobs.length
    ? `<div class="scroll"><table><thead><tr><th>Job</th><th>What</th><th>Due</th><th>Tip</th><th>You receive (est.)</th></tr></thead><tbody>${rows}</tbody></table></div>
       <button class="btn" data-action="run" data-ids="${ids.join(",")}">${state.address ? `Run ${jobs.length} job${jobs.length === 1 ? "" : "s"}` : "Connect wallet to run"}</button>`
    : `<p class="empty">Nothing is due right now. ${total} job${total === 1n ? "" : "s"} on the books.</p>`;

  return `
    <section>
      <h1>Executors</h1>
      <p class="lede">These jobs are due, funded, and capped high enough that you can't lose money running them.
      Run them and the contract pays you back your gas plus each tip, in the same transaction.</p>
      ${body}
      <h2>Run it unattended</h2>
      <p class="muted">The repository ships a small bot that polls <code>runnable()</code>, simulates, and calls
      <code>runBatch()</code>. It needs an RPC URL and a funded key — nothing else.</p>
      <pre><code>PRIVATE_KEY=0x… TOCK=${DEPLOYED ? TOCK : "0x…"} npm run keeper</code></pre>
    </section>`;
}

function how(): string {
  return `
    <section class="narrow">
      <h1>How it works</h1>
      <p class="lede">Three accounts are involved, and the separation between them is the safety model.</p>
      <h2>Your gas balance</h2>
      <p>USDC you deposit into Tock to pay executors. It is only ever spent on runs of your own jobs, never more
      than a job's cap per run, and you can withdraw it at any time.</p>
      <h2>Your agent account</h2>
      <p>A small contract created for you with your first job. Every job runs <em>from</em> it, so the contract
      being called sees your agent as the caller — never Tock, and never another user. Scheduled payments are
      sent from its balance. Only Tock (for your jobs) and you can use it; you can pull funds out whenever you like.</p>
      <h2>The executor</h2>
      <p>Anyone. When a job is due they call <code>run</code>; Tock makes the call through your agent, measures
      the gas, and pays the executor <code>gas × base fee + tip</code> from your gas balance. The refund uses the
      block's base fee, not the price the executor bid, so they can't inflate it.</p>
      <h2>Guard rails</h2>
      <ul>
        <li>A job gets the full gas you set for it, or the run reverts. An executor can't starve it to make it fail.</li>
        <li>If network fees rise above what your cap covers, the job waits rather than leaving an executor out of pocket.</li>
        <li>A call that fails still pays the executor, who did the work — but three failures in a row pause the job.</li>
        <li>A late run doesn't cause a burst of catch-up runs. The next one is a full interval later.</li>
        <li>There is no owner, no fee switch and no upgrade path in the contract.</li>
      </ul>
      <h2>Scheduling a call from your own contract's point of view</h2>
      <pre><code>// Anyone may call this; it is safe to automate.
function harvest() external {
    require(block.timestamp >= lastHarvest + 1 days, "too soon");
    lastHarvest = block.timestamp;
    // …
}</code></pre>
      <p>Schedule <code>harvest()</code> daily and it runs without you. If the function should only be callable by
      your automation, check <code>msg.sender</code> against your agent's address, shown on the My jobs page.</p>
      <p class="muted small">Tock is an early proof of concept and has not been professionally audited. Use small amounts.</p>
    </section>`;
}

const notFound = (message = "Page not found.") =>
  `<section class="narrow center"><h1>Nothing here</h1><p class="muted">${message}</p><a class="btn" href="#/">Home</a></section>`;

// ──────────────────────────── actions ────────────────────────────

/** Parse a decimal USDC amount into native units (18 decimals). */
function usdc(text: string, allowZero = true): bigint {
  const clean = text.trim();
  if (!/^\d+(\.\d{1,18})?$/.test(clean)) throw new Error(`"${text}" isn't a valid amount.`);
  const v = parseEther(clean);
  if (!allowZero && v === 0n) throw new Error("Enter an amount greater than zero.");
  return v;
}

function int(text: string, name: string): number {
  if (!/^\d+$/.test(text.trim())) throw new Error(`${name} must be a whole number.`);
  return Number(text.trim());
}

async function submitJob(form: HTMLFormElement, button: HTMLButtonElement) {
  if (!state.address) return connect();
  const me = state.address;
  const f = new FormData(form);
  const get = (k: string) => String(f.get(k) ?? "");

  let target: string, data: Hex, value: bigint;
  if (tab === "payment") {
    target = get("to").trim();
    data = "0x";
    value = usdc(get("amount"), false);
  } else {
    target = get("target").trim();
    const signature = get("signature").trim();
    let args: unknown;
    try {
      args = JSON.parse(get("args").trim() || "[]");
    } catch {
      throw new Error("Arguments must be a JSON array, like [] or [\"0x…\", \"100\"].");
    }
    if (!Array.isArray(args)) throw new Error("Arguments must be a JSON array.");
    const abi = parseAbi([`function ${signature.replace(/^function\s+/, "")}`] as string[]) as Abi;
    const fn = abi.find((item) => item.type === "function");
    if (!fn) throw new Error("Write the function like harvest() or transfer(address,uint256).");
    data = encodeFunctionData({ abi, functionName: fn.name, args });
    value = usdc(get("amount") || "0");
  }
  if (!isAddress(target)) throw new Error("That doesn't look like an address.");

  const interval = Number(get("interval"));
  const maxFee = usdc(get("maxFee"), false);
  const tip = usdc(get("tip"));
  if (tip > maxFee) throw new Error("The tip can't be larger than the most a run may cost.");
  const deposit = usdc(get("deposit") || "0");
  const prefund = BigInt(get("prefund") || "0");
  const spec = {
    target: target as Address,
    data,
    value,
    interval,
    firstRun: 0,
    gasLimit: int(get("gasLimit"), "Gas for the call"),
    maxFee,
    tip,
    maxRuns: get("maxRuns").trim() ? int(get("maxRuns"), "Stop after") : 0,
    name: get("name").trim() || (tab === "payment" ? "Payment" : "Contract call"),
  };

  await act(button, "Confirm in wallet…", async () => {
    await send({ ...tock, functionName: "createJob", args: [spec], value: deposit });
    if (prefund > 0n) {
      const agent = await client.readContract({ ...tock, functionName: "agentOf", args: [me] });
      await transfer(agent, value * prefund);
    }
    const needsFunding = value > 0n && prefund === 0n;
    toast(needsFunding ? "Scheduled. Fund your agent so the payments can go out." : prefund > 0n ? "Scheduled and funded." : "Scheduled.");
    location.hash = "#/jobs";
  });
}

app.addEventListener("submit", (e) => {
  e.preventDefault();
  const form = e.target as HTMLFormElement;
  if (form.id !== "job-form") return;
  submitJob(form, form.querySelector("button[type=submit]")!).catch((err) => toast(explain(err), "err"));
});

app.addEventListener("click", (e) => {
  const button = (e.target as HTMLElement).closest<HTMLButtonElement>("[data-action]");
  if (!button) return;
  const { action, id, ids, agent } = button.dataset;

  if (action === "tab") {
    tab = button.dataset.tab as typeof tab;
    return void render();
  }
  if (action === "connect") return void connect().catch((err) => toast(explain(err), "err"));
  if (action === "disconnect") return disconnect();
  if (!state.address) return void connect().catch((err) => toast(explain(err), "err"));
  const me = state.address;
  const amountFrom = (selector: string) => usdc(document.querySelector<HTMLInputElement>(selector)!.value, false);
  const done = async (message: string) => {
    toast(message);
    await render();
  };

  const actions: Record<string, [string, () => Promise<void>]> = {
    deposit: ["Adding…", async () => {
      await send({ ...tock, functionName: "deposit", value: amountFrom("#gas-amount") });
      await done("Added to your gas balance.");
    }],
    withdraw: ["Withdrawing…", async () => {
      await send({ ...tock, functionName: "withdraw", args: [amountFrom("#gas-amount"), me] });
      await done("Withdrawn to your wallet.");
    }],
    "fund-agent": ["Sending…", async () => {
      await transfer(agent as Address, amountFrom("#agent-amount"));
      await done("Agent funded.");
    }],
    "drain-agent": ["Withdrawing…", async () => {
      // The owner can make its agent do anything, including send its balance home.
      await send({ address: agent as Address, abi: agentAbi, functionName: "exec", args: [me, amountFrom("#agent-amount"), "0x"] });
      await done("Withdrawn from your agent.");
    }],
    pause: ["Pausing…", async () => {
      await send({ ...tock, functionName: "pause", args: [BigInt(id!)] });
      await done("Paused.");
    }],
    resume: ["Resuming…", async () => {
      await send({ ...tock, functionName: "resume", args: [BigInt(id!)] });
      await done("Resumed. The next run is one interval from now.");
    }],
    cancel: ["Ending…", async () => {
      await send({ ...tock, functionName: "cancel", args: [BigInt(id!)] });
      await done("Job ended.");
    }],
    run: ["Running…", async () => {
      await send({ ...tock, functionName: "runBatch", args: [ids!.split(",").map(BigInt)] });
      await done("Done. Your gas refund and tips are in your wallet.");
    }],
  };
  const entry = actions[action!];
  if (!entry) return;
  if (action === "cancel" && !confirm("End this job? It can't be restarted.")) return;
  void act(button, entry[0], entry[1]);
});

// ───────────────────────────── router ────────────────────────────

let renderId = 0;

async function view(): Promise<string> {
  const [, route] = (location.hash || "#/").split("/");
  if (!DEPLOYED && route && route !== "how") {
    return `<section class="narrow center"><h1>Launching shortly</h1><p class="muted">The contract is being deployed to
      Arc mainnet. Until then you can read how it works.</p><a class="btn" href="#/how">How it works</a></section>`;
  }
  switch (route ?? "") {
    case "":
      return home();
    case "new":
      return schedule();
    case "jobs":
      return myJobs();
    case "run":
      return executors();
    case "how":
      return how();
    default:
      return notFound();
  }
}

async function render() {
  const id = ++renderId;
  // Never leave a blank page while the chain is being read.
  if (!app.firstChild) app.innerHTML = `${header()}<main><p class="empty">Reading from Arc…</p></main>${footer()}`;
  let main: string;
  try {
    main = await view().catch(async () => {
      await new Promise((r) => setTimeout(r, 1200)); // one quiet retry before bothering the visitor
      return view();
    });
  } catch (err) {
    console.error(err);
    main = `<section class="narrow center"><h1>Couldn't load</h1>
      <p class="muted">The app couldn't reach any Arc RPC endpoint from this browser. An ad blocker, VPN or DNS
      filter is the usual cause.</p><p class="muted small">${esc(explain(err))}</p>
      <button class="btn" onclick="location.reload()">Try again</button></section>`;
  }
  if (id !== renderId) return; // a newer navigation finished first
  const prelaunch = DEPLOYED ? "" : `<p class="banner">Preview — the contract is not on Arc mainnet yet.</p>`;
  const banner = state.wrongChain ? `<p class="banner">Your wallet is on another network. Actions will ask to switch to Arc.</p>` : "";
  app.innerHTML = `${header()}${prelaunch}${banner}<main>${main}</main>${footer()}`;
}

window.addEventListener("hashchange", () => {
  window.scrollTo(0, 0);
  void render();
});
onWallet(() => void render());
void restore().finally(render);
