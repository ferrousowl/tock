// Measures what an executor really nets on each route, with real transactions and a zero tip.
// This is how RUN_OVERHEAD and TX_OVERHEAD in Tock.sol were calibrated.
//
//   arc-anvil --network arc --fork-url https://rpc.mainnet.arc.io     (in another terminal)
//   (cd ../contracts && arc-forge build) && node calibrate.mjs
import { createPublicClient, createWalletClient, encodeFunctionData, http, parseAbi, parseEther } from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import fs from "fs";
const RPC = process.env.RPC_URL ?? "http://127.0.0.1:8545", MCF = "0x522fAf9A91c41c443c66765030741e4AaCe147D0";
const art = JSON.parse(fs.readFileSync("../contracts/out/Tock.sol/Tock.json", "utf8"));
const chain = { id: 5042, name: "Arc", nativeCurrency: { name: "USDC", symbol: "USDC", decimals: 18 }, rpcUrls: { default: { http: [RPC] } } };
const pub = createPublicClient({ chain, transport: http(RPC) });
const rpc = (method, params = []) => pub.request({ method, params });
const mk = async () => { const a = privateKeyToAccount(generatePrivateKey()); await rpc("anvil_setBalance", [a.address, "0x" + parseEther("100").toString(16)]); return createWalletClient({ account: a, chain, transport: http(RPC) }); };
const wait = (h) => pub.waitForTransactionReceipt({ hash: h });
const mcf = parseAbi(["struct Call3 { address target; bool allowFailure; bytes callData; }", "struct Result { bool success; bytes returnData; }", "function aggregate3(Call3[] calls) returns (Result[])"]);

const dep = await mk();
const r = await wait(await dep.deployContract({ abi: art.abi, bytecode: art.bytecode.object }));
const tock = { address: r.contractAddress, abi: art.abi };
console.log("deployed", tock.address, "gas", r.gasUsed);
const N = 21, payee = privateKeyToAccount(generatePrivateKey()).address;
for (let i = 0; i < N; i++) {
  const o = await mk(); // one owner per job: each has its own Agent, the realistic worst case
  const spec = { target: payee, data: "0x", value: parseEther("0.01"), interval: 3600, firstRun: 0, gasLimit: 60000, maxFee: parseEther("0.05"), tip: 0n, maxRuns: 0, name: "calib" };
  const c = await wait(await o.writeContract({ ...tock, functionName: "createJob", args: [spec], value: parseEther("1") }));
  if (i === 0) console.log("createJob (deploys Agent) gas", c.gasUsed);
  const agent = await pub.readContract({ ...tock, functionName: "agentOf", args: [o.account.address] });
  await wait(await o.sendTransaction({ to: agent, value: parseEther("1") }));
}
async function runRoute(label, n, send) {
  const k = await mk();
  const before = await pub.getBalance({ address: k.account.address });
  const rc = await wait(await send(k));
  const after = await pub.getBalance({ address: k.account.address });
  const base = (await pub.getBlock({ blockNumber: rc.blockNumber })).baseFeePerGas;
  const refundGas = Number((after - before + rc.gasUsed * rc.effectiveGasPrice) / base);
  console.log(`${label}: ${rc.status} gasUsed ${rc.gasUsed} refund(gas-eq) ${refundGas} => ${((100 * refundGas) / Number(rc.gasUsed)).toFixed(1)}% of cost, net/job ${((refundGas - Number(rc.gasUsed)) / n).toFixed(0)} gas`);
}
const ids = Array.from({ length: N }, (_, i) => BigInt(i));
await runRoute("single run            ", 1, (k) => k.writeContract({ ...tock, functionName: "run", args: [ids[0]] }));
await runRoute("runBatch x1           ", 1, (k) => k.writeContract({ ...tock, functionName: "runBatch", args: [ids.slice(1, 2)] }));
await runRoute("runBatch x9           ", 9, (k) => k.writeContract({ ...tock, functionName: "runBatch", args: [ids.slice(2, 11)] }));
await runRoute("Multicall3From loop x10", 10, (k) => k.writeContract({ address: MCF, abi: mcf, functionName: "aggregate3", args: [ids.slice(11, 21).map((id) => ({ target: tock.address, allowFailure: false, callData: encodeFunctionData({ abi: art.abi, functionName: "run", args: [id] }) }))] }));
console.log("payee received", Number(await pub.getBalance({ address: payee })) / 1e18, "USDC from", N, "jobs");
