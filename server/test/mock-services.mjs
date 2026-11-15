// Fake Apple, Claude and Instagram servers for local testing.
import http from "node:http";
import crypto from "node:crypto";

export const log = [];
const { publicKey, privateKey } = crypto.generateKeyPairSync("rsa", { modulusLength: 2048 });
const jwk = { ...publicKey.export({ format: "jwk" }), kid: "test-kid", alg: "RS256", use: "sig" };

export function appleToken({ sub = "apple-user-1", aud = "com.chasemorrin.clipstudio", exp = Math.floor(Date.now() / 1000) + 600 } = {}) {
  const b = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
  const head = b({ alg: "RS256", kid: "test-kid" });
  const body = b({ iss: "https://appleid.apple.com", aud, sub, exp, iat: exp - 600 });
  const sig = crypto.sign("RSA-SHA256", Buffer.from(`${head}.${body}`), privateKey).toString("base64url");
  return `${head}.${body}.${sig}`;
}

let containerN = 0;
const containers = new Map(); // id -> { checks, fail, fetched }
export const state = { failNextContainer: false, claudeBodies: [] };

function send(res, code, obj) { res.writeHead(code, { "content-type": "application/json" }); res.end(JSON.stringify(obj)); }

export function start(port) {
  const server = http.createServer(async (req, res) => {
    const url = new URL(req.url, `http://127.0.0.1:${port}`);
    let body = "";
    for await (const ch of req) body += ch;
    log.push(`${req.method} ${url.pathname}${url.search}`);
    const p = url.pathname;

    if (p === "/apple/keys") return send(res, 200, { keys: [jwk] });

    if (p === "/v1/messages") {
      const b = JSON.parse(body);
      state.claudeBodies.push(b);
      if (req.headers["x-api-key"] !== "test-anthropic-key") return send(res, 401, { error: { message: "bad key" } });
      return send(res, 200, { content: [{ type: "text", text: `echo:${b.messages[0].content}` }], stop_reason: "end_turn", usage: { input_tokens: 5, output_tokens: 3 } });
    }

    if (p === "/oauth/access_token") {
      const f = new URLSearchParams(body);
      if (f.get("code") !== "good-code" || f.get("client_secret") !== "test-ig-secret") return send(res, 400, { error_message: "bad code" });
      return send(res, 200, { data: [{ access_token: "short-tok", user_id: "1789", permissions: "instagram_business_basic" }] });
    }
    if (p === "/access_token") return send(res, 200, { access_token: "long-tok-1", token_type: "bearer", expires_in: 5184000 });
    if (p === "/refresh_access_token") return send(res, 200, { access_token: "long-tok-refreshed", token_type: "bearer", expires_in: 5184000 });
    if (p === "/v25.0/me") return send(res, 200, { user_id: "1789", username: "chasemorrin_test" });

    let m;
    if ((m = p.match(/^\/v25\.0\/1789\/media$/)) && req.method === "POST") {
      const q = url.searchParams;
      const mediaUrl = q.get("video_url") || q.get("image_url");
      let fetched = null;
      if (mediaUrl) {
        // Instagram downloads the file: make sure the signed link really works.
        const r = await fetch(mediaUrl);
        fetched = { status: r.status, bytes: (await r.arrayBuffer()).byteLength };
        if (r.status !== 200) return send(res, 400, { error: { message: `could not download media (${r.status})`, code: 9004 } });
      }
      const id = `c${++containerN}`;
      containers.set(id, { checks: 0, fail: state.failNextContainer, fetched, params: Object.fromEntries(q) });
      state.failNextContainer = false;
      return send(res, 200, { id });
    }
    if ((m = p.match(/^\/v25\.0\/1789\/media_publish$/))) {
      const cid = url.searchParams.get("creation_id");
      if (!containers.has(cid)) return send(res, 400, { error: { message: "unknown container" } });
      return send(res, 200, { id: `media_${cid}` });
    }
    if ((m = p.match(/^\/v25\.0\/(c\d+)$/))) {
      const c = containers.get(m[1]);
      if (!c) return send(res, 400, { error: { message: "unknown container" } });
      c.checks++;
      if (c.fail) return send(res, 200, { status_code: "ERROR", status: "Error: unsupported video" });
      const video = c.params.media_type === "REELS" || c.params.media_type === "VIDEO" || c.params.media_type === "CAROUSEL";
      return send(res, 200, { status_code: video && c.checks < 2 ? "IN_PROGRESS" : "FINISHED" });
    }
    if ((m = p.match(/^\/v25\.0\/(media_c\d+)$/))) return send(res, 200, { permalink: `https://www.instagram.com/reel/${m[1]}/` });

    send(res, 404, { error: { message: `mock: no route ${p}` } });
  });
  return new Promise((r) => server.listen(port, "127.0.0.1", () => r(server)));
}

export { containers };
