// Runs due Tock jobs and collects the gas refund + tips.
//
//   PRIVATE_KEY=0x… TOCK=0x… npm run keeper
//
// Optional: RPC_URL (default Arc mainnet), INTERVAL seconds (default 60), BATCH (default 10).
import { createPublicClient, createWalletClient, http, parseAbi } from "viem";
import { privateKeyToAccount } from "viem/accounts";

const { PRIVATE_KEY, TOCK, RPC_URL = "https://rpc.mainnet.arc.io" } = process.env;
if (!PRIVATE_KEY || !TOCK) {
  console.error("Set PRIVATE_KEY and TOCK.");
  process.exit(1);
}
const INTERVAL = Number(process.env.INTERVAL ?? 60) * 1000;
const BATCH = Number(process.env.BATCH ?? 10);

const abi = parseAbi([
  "function jobCount() view returns (uint256)",
  "function runnable(uint256 from, uint256 count, uint256 baseFee) view returns (uint256[])",
  "function worstCaseGas(uint256 jobId) view returns (uint256)",
  "function runBatch(uint256[] jobIds) returns (uint256)",
]);

const transport = http(RPC_URL);
const account = privateKeyToAccount(PRIVATE_KEY);
const reader = createPublicClient({ transport });
const chain = { id: await reader.getChainId(), name: "Arc", nativeCurrency: { name: "USDC", symbol: "USDC", decimals: 18 }, rpcUrls: { default: { http: [RPC_URL] } } };
const wallet = createWalletClient({ account, chain, transport });
const tock = { address: TOCK, abi };

const log = (...a) => console.log(new Date().toISOString(), ...a);
log(`keeper ${account.address} watching ${TOCK} on chain ${chain.id}`);

async function tick() {
  const total = await reader.readContract({ ...tock, functionName: "jobCount" });
  // runnable() lists jobs that are due, funded, and capped high enough to cover a run that burns
  // its whole gas limit at this base fee — so running them cannot lose money. The base fee is an
  // argument because a read-only call on Arc sees block.basefee as zero.
  const { baseFeePerGas } = await reader.getBlock();
  const due = [];
  for (let from = 0n; from < total; from += 500n) {
    due.push(...(await reader.readContract({ ...tock, functionName: "runnable", args: [from, 500n, baseFeePerGas] })));
  }
  for (let i = 0; i < due.length; i += BATCH) {
    const ids = due.slice(i, i + BATCH);
    // Send each job's worst-case gas rather than an estimate: a target may behave differently
    // when it is simulated, and unused gas costs nothing.
    const worst = await Promise.all(ids.map((id) => reader.readContract({ ...tock, functionName: "worstCaseGas", args: [id] })));
    const gas = worst.reduce((a, b) => a + b, 0n) + 50_000n;
    // Simulate first: jobs sharing one owner's gas balance can all be listed yet not all be payable.
    const { result: ran, request } = await reader.simulateContract({ ...tock, functionName: "runBatch", args: [ids], account, gas, maxFeePerGas: baseFeePerGas * 2n });
    if (ran === 0n) continue;
    const hash = await wallet.writeContract(request);
    const receipt = await reader.waitForTransactionReceipt({ hash });
    log(`ran ${ran}/${ids.length} job(s) [${ids.join(", ")}] ${receipt.status} ${hash}`);
  }
}

for (;;) {
  try {
    await tick();
  } catch (err) {
    log("error:", err.shortMessage ?? err.message);
  }
  await new Promise((r) => setTimeout(r, INTERVAL));
}
