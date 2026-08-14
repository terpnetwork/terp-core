/**
 * Terp local faucet (Node HTTP).
 *
 * Design (not genesis-bound to a fixed faucet address):
 *  - FUNDER_WALLET_NAME: key that already has coins (localterp genesis has
 *    validator/a/b/c/d — default funder is "a"). Not the public faucet identity.
 *  - FAUCET_WALLET_NAME: hot wallet the faucet spends from (default "faucet").
 *    Created on demand, or recovered from FAUCET_KEY_MNEMONIC.
 *  - On ready: if faucet balance is low, funder bank-sends to faucet address.
 *  - Clients hit GET /faucet?address=… without knowing genesis faucet keys.
 *
 * Env:
 *   TERPD              binary (default: terpd)
 *   CHAIN_ID           chain-id for txs
 *   RPC_NODE           tendermint RPC (default: http://127.0.0.1:26657)
 *   FUNDER_WALLET_NAME keyring name with funds (default: a)
 *   FAUCET_WALLET_NAME keyring name faucet spends from (default: faucet)
 *   FAUCET_KEY_MNEMONIC optional 24-word recover for faucet key
 *   FAUCET_AMOUNT      amount per denom per request (default 1000000000)
 *   FAUCET_TOPUP       amount funder sends when top-up (default 1000000000000)
 *   FAUCET_MIN_BALANCE min per-denom balance before top-up (default 10000000000)
 *   DENOMS             comma list (default uterp,uthiol)
 *   KEYRING_BACKEND    default test
 *   FAUCET_PORT        listen port (default 5000)
 */

const http = require("http");
const querystring = require("querystring");
const { exec } = require("child_process");

const TERPD = process.env.TERPD || "terpd";
const CHAIN_ID = process.env.CHAIN_ID || process.env.CHAINID || "120u-1";
const RPC_NODE = process.env.RPC_NODE || "http://127.0.0.1:26657";
const FUNDER_WALLET_NAME = process.env.FUNDER_WALLET_NAME || "a";
const FAUCET_WALLET_NAME = process.env.FAUCET_WALLET_NAME || "faucet";
const FAUCET_KEY_MNEMONIC = (process.env.FAUCET_KEY_MNEMONIC || "").trim();
const FAUCET_AMOUNT = process.env.FAUCET_AMOUNT || "1000000000";
const FAUCET_TOPUP = process.env.FAUCET_TOPUP || "1000000000000";
const FAUCET_MIN_BALANCE = BigInt(process.env.FAUCET_MIN_BALANCE || "10000000000");
const DENOMS = (process.env.DENOMS || "uterp,uthiol").split(",").map((d) => d.trim()).filter(Boolean);
const KEYRING = process.env.KEYRING_BACKEND || "test";
const PORT = parseInt(process.env.FAUCET_PORT || "5000", 10);

let faucetAddress;
let ready = false;
let readyError = null;
let topupInFlight = null;

function execShellCommand(cmd, { ignoreStderr = true } = {}) {
  return new Promise((resolve, reject) => {
    exec(cmd, { maxBuffer: 10 * 1024 * 1024 }, (error, stdout, stderr) => {
      if (error) {
        reject(new Error(`${error.message}${stderr ? `\n${stderr}` : ""}`));
        return;
      }
      if (stderr && !ignoreStderr) {
        reject(new Error(stderr));
        return;
      }
      const out = (stdout || "").trim();
      if (!out) {
        resolve(null);
        return;
      }
      try {
        resolve(JSON.parse(out));
      } catch (_) {
        resolve(out);
      }
    });
  });
}

function execShellRaw(cmd) {
  return new Promise((resolve, reject) => {
    exec(cmd, { maxBuffer: 10 * 1024 * 1024 }, (error, stdout, stderr) => {
      if (error) {
        reject(new Error(`${error.message}${stderr ? `\n${stderr}` : ""}`));
        return;
      }
      resolve({ stdout: (stdout || "").trim(), stderr: (stderr || "").trim() });
    });
  });
}

async function waitForRpc(maxMs = 120000) {
  const start = Date.now();
  while (Date.now() - start < maxMs) {
    try {
      const r = await execShellCommand(
        `${TERPD} status --node ${RPC_NODE} 2>/dev/null || curl -fsS ${RPC_NODE}/status`,
        { ignoreStderr: true }
      );
      if (r) return;
    } catch (_) {
      /* retry */
    }
    await new Promise((r) => setTimeout(r, 500));
  }
  throw new Error(`RPC not ready within ${maxMs}ms at ${RPC_NODE}`);
}

async function listKeys() {
  const result = await execShellCommand(
    `${TERPD} keys list --output json --keyring-backend ${KEYRING}`,
    { ignoreStderr: true }
  );
  return Array.isArray(result) ? result : [];
}

async function ensureFaucetKey() {
  const keys = await listKeys();
  const existing = keys.find((k) => k.name === FAUCET_WALLET_NAME);
  if (existing) {
    faucetAddress = existing.address;
    console.log(`[faucet] using existing key ${FAUCET_WALLET_NAME}=${faucetAddress}`);
    return faucetAddress;
  }

  if (FAUCET_KEY_MNEMONIC) {
    console.log(`[faucet] recovering ${FAUCET_WALLET_NAME} from FAUCET_KEY_MNEMONIC`);
    // printf avoids echo -e quirks; yes pipe for overwrite
    await execShellRaw(
      `printf '%s\n' '${FAUCET_KEY_MNEMONIC.replace(/'/g, "'\\''")}' | ${TERPD} keys add ${FAUCET_WALLET_NAME} --recover --keyring-backend ${KEYRING} --output json 2>/dev/null || true`
    );
  } else {
    console.log(`[faucet] generating new key ${FAUCET_WALLET_NAME} (not in genesis)`);
    await execShellRaw(
      `${TERPD} keys add ${FAUCET_WALLET_NAME} --keyring-backend ${KEYRING} --output json 2>/dev/null || true`
    );
  }

  const after = await listKeys();
  const k = after.find((x) => x.name === FAUCET_WALLET_NAME);
  if (!k) {
    throw new Error(`failed to create/recover faucet key ${FAUCET_WALLET_NAME}`);
  }
  faucetAddress = k.address;
  console.log(`[faucet] ${FAUCET_WALLET_NAME}=${faucetAddress}`);
  return faucetAddress;
}

async function getAddress(keyName) {
  const keys = await listKeys();
  const k = keys.find((x) => x.name === keyName);
  return k ? k.address : undefined;
}

async function balanceOf(address, denom) {
  try {
    const q = await execShellCommand(
      `${TERPD} q bank balances ${address} --node ${RPC_NODE} --output json`,
      { ignoreStderr: true }
    );
    const bals = (q && q.balances) || [];
    const hit = bals.find((b) => b.denom === denom);
    return hit ? BigInt(hit.amount) : 0n;
  } catch (_) {
    return 0n;
  }
}

async function needsTopup(address) {
  for (const d of DENOMS) {
    const bal = await balanceOf(address, d);
    if (bal < FAUCET_MIN_BALANCE) return true;
  }
  return false;
}

async function fundFaucetFromFunder() {
  const funderAddr = await getAddress(FUNDER_WALLET_NAME);
  if (!funderAddr) {
    throw new Error(
      `FUNDER_WALLET_NAME=${FUNDER_WALLET_NAME} not in keyring — cannot top up faucet without a funded funder key`
    );
  }
  const dest = await ensureFaucetKey();
  const coins = DENOMS.map((d) => `${FAUCET_TOPUP}${d}`).join(",");
  const cmd =
    `${TERPD} tx bank send ${funderAddr} ${dest} ${coins}` +
    ` --from ${FUNDER_WALLET_NAME} --node ${RPC_NODE}` +
    ` --gas-prices 0.25uterp --keyring-backend ${KEYRING}` +
    ` --chain-id ${CHAIN_ID} --output json -y`;
  console.log(`[faucet] top-up from funder ${FUNDER_WALLET_NAME} → ${dest}: ${coins}`);
  const result = await execShellCommand(cmd, { ignoreStderr: true });
  const txhash = result && result.txhash;
  console.log(`[faucet] top-up txhash=${txhash || JSON.stringify(result)}`);
  // Wait a block for bank balance
  await new Promise((r) => setTimeout(r, 1500));
  return txhash;
}

async function ensureFunded() {
  if (topupInFlight) return topupInFlight;
  topupInFlight = (async () => {
    try {
      const addr = await ensureFaucetKey();
      if (await needsTopup(addr)) {
        await fundFaucetFromFunder();
      } else {
        console.log(`[faucet] balance OK for ${addr}`);
      }
    } finally {
      topupInFlight = null;
    }
  })();
  return topupInFlight;
}

async function sendFromFaucet(destAddress, amount) {
  await ensureFunded();
  const src = await ensureFaucetKey();
  // Re-check after concurrent requests may have drained
  if (await needsTopup(src)) {
    await fundFaucetFromFunder();
  }
  const coins = DENOMS.map((d) => `${amount}${d}`).join(",");
  const cmd =
    `${TERPD} tx bank send ${src} ${destAddress} ${coins}` +
    ` --from ${FAUCET_WALLET_NAME} --node ${RPC_NODE}` +
    ` --gas-prices 0.25uterp --keyring-backend ${KEYRING}` +
    ` --chain-id ${CHAIN_ID} --output json -y`;
  console.log(`[faucet] send ${coins} → ${destAddress}`);
  const result = await execShellCommand(cmd, { ignoreStderr: true });
  if (!result || !result.txhash) {
    throw new Error(`bank send failed: ${JSON.stringify(result)}`);
  }
  return result.txhash;
}

async function bootstrap() {
  try {
    console.log(
      `[faucet] bootstrap TERPD=${TERPD} chain=${CHAIN_ID} rpc=${RPC_NODE} funder=${FUNDER_WALLET_NAME} faucet=${FAUCET_WALLET_NAME}`
    );
    await waitForRpc();
    await ensureFaucetKey();
    await ensureFunded();
    ready = true;
    readyError = null;
    console.log("[faucet] READY");
  } catch (e) {
    ready = false;
    readyError = e.message || String(e);
    console.error("[faucet] bootstrap failed:", readyError);
    // Keep retrying so /status flips ready when chain catches up
    setTimeout(() => {
      bootstrap().catch(() => {});
    }, 3000);
  }
}

const server = http.createServer(async (req, res) => {
  const json = (code, obj) => {
    res.writeHead(code, { "Content-Type": "application/json" });
    res.write(JSON.stringify(obj));
    res.end();
  };

  try {
    if (req.url === "/" || req.url === "/status" || req.url === "/health") {
      if (!ready) {
        // Still report listening so clients know process is up; 503 until funded
        json(readyError ? 503 : 200, {
          ready: false,
          error: readyError,
          funder: FUNDER_WALLET_NAME,
          faucet_wallet: FAUCET_WALLET_NAME,
          faucet_address: faucetAddress || null,
          amount: FAUCET_AMOUNT,
          denoms: DENOMS,
        });
        return;
      }
      json(200, {
        ready: true,
        faucet_address: faucetAddress,
        funder: FUNDER_WALLET_NAME,
        faucet_wallet: FAUCET_WALLET_NAME,
        amount: FAUCET_AMOUNT,
        denoms: DENOMS,
      });
      return;
    }

    if (req.url.startsWith("/faucet")) {
      if (!ready) {
        json(503, { error: readyError || "faucet not ready" });
        return;
      }
      if (!req.url.startsWith("/faucet?address=")) {
        json(400, { error: "address is required" });
        return;
      }
      const address = querystring.parse(req.url)["/faucet?address"];
      if (!address || !String(address).startsWith("terp")) {
        json(400, { error: "valid terp address required" });
        return;
      }
      const txhash = await sendFromFaucet(address, FAUCET_AMOUNT);
      json(200, { txhash, from: faucetAddress });
      return;
    }

    res.end("Invalid Request!");
  } catch (err) {
    console.error("[faucet] request error", err);
    json(500, { error: `${err.message || err}` });
  }
});

server.listen(PORT, "0.0.0.0", () => {
  console.log(`Terp Faucet listening on 0.0.0.0:${PORT} ...`);
  bootstrap().catch((e) => console.error(e));
});
