import { BaseError, ContractFunctionRevertedError, formatEther, type Address } from "viem";

/** Escape text for interpolation into HTML. Job names are user-controlled on-chain strings. */
export const esc = (s: unknown) =>
  String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);

export const short = (a: Address) => `${a.slice(0, 6)}…${a.slice(-4)}`;

/** Native USDC has 18 decimals. Shows cents, or more places for amounts under a cent. */
export function usd(wei: bigint, maxFrac = 2): string {
  const n = Number(formatEther(wei));
  const frac = n !== 0 && Math.abs(n) < 0.01 ? 5 : maxFrac;
  return `$${n.toLocaleString("en-US", { minimumFractionDigits: Math.min(2, frac), maximumFractionDigits: frac })}`;
}

const UNITS: [number, string][] = [
  [365 * 86400, "year"],
  [30 * 86400, "month"],
  [7 * 86400, "week"],
  [86400, "day"],
  [3600, "hour"],
  [60, "minute"],
];

/** "month", "2 weeks", "90 minutes" */
export function every(seconds: number): string {
  for (const [size, name] of UNITS) {
    if (seconds % size === 0) {
      const n = seconds / size;
      return n === 1 ? name : `${n} ${name}s`;
    }
  }
  return `${seconds} seconds`;
}

export function date(unix: number): string {
  return new Date(unix * 1000).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });
}

/** "in 3 days", "2 hours ago". `now` is chain time, which is what decides whether a job is due. */
export function relative(unix: number, now: number): string {
  const diff = unix - now;
  const abs = Math.abs(diff);
  const [size, name] = UNITS.find(([s]) => abs >= s) ?? [1, "second"];
  const n = Math.max(1, Math.round(abs / size));
  const text = `${n} ${name}${n === 1 ? "" : "s"}`;
  return diff >= 0 ? `in ${text}` : `${text} ago`;
}

const REVERTS: Record<string, string> = {
  BadParams: "Those job settings aren't valid. Check the interval (1 minute or more), the gas limit, that the tip is no larger than the fee cap, and that the call data is under 1 KB.",
  Underfunded: "The owner's gas balance can't cover this run.",
  FeeCapTooLow: "Network fees are currently above this job's fee cap, so it is waiting.",
  JobInactive: "This job is paused or has ended.",
  NotDue: "This job isn't due yet.",
  NotOwner: "Only the job's owner can do that.",
  InsufficientGas: "The transaction didn't carry enough gas to run the job safely. Try again with a higher gas limit.",
  TransferFailed: "The USDC transfer was rejected by the network.",
};

/** Turn a viem error into one sentence a person can act on. */
export function explain(err: unknown): string {
  if (err instanceof BaseError) {
    const revert = err.walk((e) => e instanceof ContractFunctionRevertedError);
    if (revert instanceof ContractFunctionRevertedError) {
      const name = revert.data?.errorName;
      if (name && REVERTS[name]) return REVERTS[name];
    }
    if (/user rejected|denied/i.test(err.shortMessage)) return "Cancelled in the wallet.";
    if (/insufficient funds/i.test(err.message)) return "Not enough USDC to cover this transaction and its fee.";
    return err.shortMessage;
  }
  return err instanceof Error ? err.message : String(err);
}
