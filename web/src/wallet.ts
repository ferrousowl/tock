import {
  createWalletClient,
  custom,
  http,
  type Abi,
  type Address,
  type EIP1193Provider,
  type WalletClient,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { arc, client } from "./chain";

type State = { address?: Address; wallet?: WalletClient; wrongChain: boolean };
export const state: State = { wrongChain: false };

const listeners = new Set<() => void>();
export const onWallet = (fn: () => void) => listeners.add(fn);
const emit = () => listeners.forEach((fn) => fn());

declare global {
  interface Window {
    ethereum?: EIP1193Provider;
  }
}

let provider: EIP1193Provider | undefined;

// EIP-6963: wallets announce themselves, so we don't depend on who won the window.ethereum race.
window.addEventListener("eip6963:announceProvider", ((e: CustomEvent) => {
  provider ??= e.detail.provider;
}) as EventListener);
window.dispatchEvent(new Event("eip6963:requestProvider"));

/** Local testing only: a throwaway key against a forked chain, never set in production builds. */
function devKey(): `0x${string}` | undefined {
  return import.meta.env.DEV ? (import.meta.env.VITE_DEV_KEY as `0x${string}` | undefined) : undefined;
}

async function syncChain() {
  if (!provider) return;
  const id = Number(await provider.request({ method: "eth_chainId" }));
  state.wrongChain = id !== arc.id;
}

const REMEMBER = "tock:connected";

/** Reconnect silently after a reload if the visitor connected before and the wallet still allows it. */
export async function restore(): Promise<void> {
  if (localStorage.getItem(REMEMBER) !== "1") return;
  if (devKey()) return connect();
  const p = provider ?? window.ethereum;
  if (!p) return;
  const accounts = (await p.request({ method: "eth_accounts" })) as Address[];
  if (accounts.length > 0) await connect();
}

export async function connect(): Promise<void> {
  localStorage.setItem(REMEMBER, "1");
  const key = devKey();
  if (key) {
    const account = privateKeyToAccount(key);
    state.wallet = createWalletClient({ account, chain: arc, transport: http() });
    state.address = account.address;
    return emit();
  }

  provider ??= window.ethereum;
  if (!provider) throw new Error("No wallet found. Install MetaMask or Rabby, then reload.");
  const [address] = (await provider.request({ method: "eth_requestAccounts" })) as Address[];
  state.address = address;
  state.wallet = createWalletClient({ account: address, chain: arc, transport: custom(provider) });
  await syncChain();

  provider.on("accountsChanged", (accounts: Address[]) => {
    if (accounts.length === 0) return disconnect();
    state.address = accounts[0];
    state.wallet = createWalletClient({ account: accounts[0], chain: arc, transport: custom(provider!) });
    emit();
  });
  provider.on("chainChanged", () => void syncChain().then(emit));
  emit();
}

export function disconnect() {
  localStorage.removeItem(REMEMBER);
  state.address = undefined;
  state.wallet = undefined;
  state.wrongChain = false;
  emit();
}

/** Switch the wallet to Arc, adding the network first if it has never seen it. */
export async function ensureArc(): Promise<void> {
  if (!provider || !state.wrongChain) return;
  const hexId = `0x${arc.id.toString(16)}`;
  try {
    await provider.request({ method: "wallet_switchEthereumChain", params: [{ chainId: hexId }] });
  } catch (err) {
    if ((err as { code?: number }).code !== 4902) throw err;
    await provider.request({
      method: "wallet_addEthereumChain",
      params: [
        {
          chainId: hexId,
          chainName: arc.name,
          nativeCurrency: arc.nativeCurrency,
          rpcUrls: [...arc.rpcUrls.default.http],
          blockExplorerUrls: [arc.blockExplorers.default.url],
        },
      ],
    });
  }
  await syncChain();
  emit();
}

type Call = { address: Address; abi: Abi; functionName: string; args?: readonly unknown[]; value?: bigint };

async function settle(hash: `0x${string}`) {
  const receipt = await client.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error("Transaction reverted.");
  return receipt;
}

/** Send a transaction and wait for it. Arc finalises on inclusion, so one receipt is final. */
export async function send(call: Call) {
  const { wallet } = state;
  if (!wallet?.account) throw new Error("Connect a wallet first.");
  await ensureArc();
  return settle(await wallet.writeContract({ ...call, account: wallet.account, chain: arc }));
}

/** A plain USDC transfer. On Arc the native token is USDC, so this is an ordinary value send. */
export async function transfer(to: Address, value: bigint) {
  const { wallet } = state;
  if (!wallet?.account) throw new Error("Connect a wallet first.");
  await ensureArc();
  return settle(await wallet.sendTransaction({ to, value, account: wallet.account, chain: arc }));
}
