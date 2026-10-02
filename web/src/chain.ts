import { createPublicClient, defineChain, fallback, http, parseAbi, type Address, type Hex, type PublicClient } from "viem";

const env = import.meta.env;

/**
 * Public Arc endpoints, tried in order. They are deliberately spread over several domains: the
 * EasyPrivacy filter list blocks third-party requests to `arc.io`, which takes out every official
 * endpoint at once for visitors using Brave or uBlock Origin.
 */
const RPCS: string[] = env.VITE_RPC
  ? [env.VITE_RPC]
  : [
      "https://rpc.mainnet.arc.io",
      "https://arc-rpc.publicnode.com",
      "https://rpc.drpc.mainnet.arc.io",
      "https://arc.drpc.org",
      "https://rpc.quicknode.mainnet.arc.io",
      "https://5042.rpc.thirdweb.com",
      "https://rpc.blockdaemon.mainnet.arc.io",
    ];

/** Arc mainnet. The native token is USDC with 18 decimals, so `value` and gas are both dollars. */
export const arc = defineChain({
  id: Number(env.VITE_CHAIN_ID ?? 5042),
  name: "Arc",
  nativeCurrency: { name: "USDC", symbol: "USDC", decimals: 18 },
  rpcUrls: { default: { http: RPCS } },
  blockExplorers: { default: { name: "Arc Explorer", url: "https://explorer.arc.io" } },
  contracts: { multicall3: { address: "0xcA11bde05977b3631167028862bE2a173976CA11" } },
});

export const TOCK = (env.VITE_TOCK ?? "0x0000000000000000000000000000000000000000") as Address;
export const DEPLOYED = !/^0x0+$/.test(TOCK);

export const tockAbi = parseAbi([
  "struct JobSpec { address target; bytes data; uint128 value; uint32 interval; uint40 firstRun; uint32 gasLimit; uint128 maxFee; uint128 tip; uint32 maxRuns; string name; }",
  "struct Job { address owner; address target; uint40 nextRun; uint32 interval; uint32 gasLimit; uint32 runs; uint32 maxRuns; uint8 failures; bool active; uint128 value; uint128 maxFee; uint128 tip; bytes data; string name; }",
  "function createJob(JobSpec spec) payable returns (uint256)",
  "function deposit() payable",
  "function withdraw(uint256 amount, address to)",
  "function pause(uint256 jobId)",
  "function resume(uint256 jobId)",
  "function cancel(uint256 jobId)",
  "function run(uint256 jobId)",
  "function runBatch(uint256[] jobIds) returns (uint256)",
  "function jobCount() view returns (uint256)",
  "function getJob(uint256 jobId) view returns (Job)",
  "function jobsOf(address owner) view returns (uint256[])",
  "function balanceOf(address owner) view returns (uint256)",
  "function agentOf(address owner) view returns (address)",
  "function predictAgent(address owner) view returns (address)",
  "function worstCaseGas(uint256 jobId) view returns (uint256)",
  "function runnable(uint256 from, uint256 count, uint256 baseFee) view returns (uint256[])",
  "error NotOwner()",
  "error NotAuthorized()",
  "error BadParams()",
  "error JobInactive()",
  "error NotDue(uint40 nextRun)",
  "error Underfunded()",
  "error FeeCapTooLow()",
  "error InsufficientGas()",
  "error TransferFailed()",
  "error Reentrancy()",
]);

export const agentAbi = parseAbi(["function exec(address target, uint256 value, bytes data) returns (bool)"]);

export const client: PublicClient = createPublicClient({
  chain: arc,
  transport: fallback(RPCS.map((url) => http(url, { batch: true, timeout: 8_000, retryCount: 1 }))),
  batch: { multicall: true },
});

export type Job = {
  id: bigint;
  owner: Address;
  target: Address;
  nextRun: number;
  interval: number;
  gasLimit: number;
  runs: number;
  maxRuns: number;
  failures: number;
  active: boolean;
  value: bigint;
  maxFee: bigint;
  tip: bigint;
  data: Hex;
  name: string;
};

const read = { address: TOCK, abi: tockAbi } as const;

export async function getJobs(ids: bigint[]): Promise<Job[]> {
  const out = await Promise.all(ids.map((id) => client.readContract({ ...read, functionName: "getJob", args: [id] })));
  return out.map((j, i) => ({ id: ids[i], ...j }));
}

export const range = (n: bigint): bigint[] => Array.from({ length: Number(n) }, (_, i) => BigInt(i));
