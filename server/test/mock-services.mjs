// Fake Apple, Claude, Instagram, Google and YouTube servers for local testing.
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
export const state = { failNextContainer: false, claudeBodies: [], ytUploads: [], ytFailNext: 0, ytRevoked: [] };
let ytSession = 0;
const ytSessions = new Map();

function send(res, code, obj) { res.writeHead(code, { "content-type": "application/json" }); res.end(JSON.stringify(obj)); }

export function start(port) {
  const server = http.createServer(async (req, res) => {
    const url = new URL(req.url, `http://127.0.0.1:${port}`);
    const chunks = [];
    for await (const ch of req) chunks.push(ch);
    const raw = Buffer.concat(chunks);
    const body = raw.toString();
    log.push(`${req.method} ${url.pathname}${url.search}`);
    const p = url.pathname;

    if (p === "/apple/keys") return send(res, 200, { keys: [jwk] });

    // Google sign-in
    if (p === "/token" && req.method === "POST") {
      const f = new URLSearchParams(body);
      if (f.get("client_id") !== "test-g-client" || f.get("client_secret") !== "test-g-secret") return send(res, 401, { error: "invalid_client" });
      if (f.get("grant_type") === "authorization_code") {
        if (f.get("code") !== "good-g-code") return send(res, 400, { error: "invalid_grant", error_description: "Bad code" });
        const scope = f.get("code") === "good-g-code" ? "https://www.googleapis.com/auth/youtube.upload https://www.googleapis.com/auth/youtube.readonly" : "";
        return send(res, 200, { access_token: "ya29-1", expires_in: 3599, refresh_token: "1//refresh-1", scope, token_type: "Bearer" });
      }
      if (f.get("grant_type") === "refresh_token") {
        if (f.get("refresh_token") !== "1//refresh-1") return send(res, 400, { error: "invalid_grant", error_description: "Token has been expired or revoked." });
        return send(res, 200, { access_token: "ya29-2", expires_in: 3599, token_type: "Bearer" });
      }
    }
    if (p === "/revoke") { state.ytRevoked.push(new URLSearchParams(body).get("token")); return send(res, 200, {}); }
    const bearer = (req.headers.authorization || "").replace(/^Bearer /, "");
    if (p === "/youtube/v3/channels") {
      if (!bearer.startsWith("ya29-")) return send(res, 401, { error: { message: "Invalid Credentials" } });
      return send(res, 200, { items: [{ id: "UC123", snippet: { title: "Chase Morrin", customUrl: "@chasemorrin" } }] });
    }
    if (p === "/upload/youtube/v3/videos" && req.method === "POST") {
      if (!bearer.startsWith("ya29-")) return send(res, 401, { error: { message: "Invalid Credentials" } });
      if (state.ytFailNext > 0) { state.ytFailNext--; return send(res, 503, { error: { message: "Backend Error", errors: [{ reason: "backendError" }] } }); }
      if (url.searchParams.get("uploadType") !== "resumable") return send(res, 400, { error: { message: "expected resumable" } });
      const id = ++ytSession;
      ytSessions.set(id, { meta: JSON.parse(body), length: Number(req.headers["x-upload-content-length"]), type: req.headers["x-upload-content-type"], bearer });
      res.writeHead(200, { location: `http://127.0.0.1:${port}/upload-session/${id}` });
      return res.end();
    }
    if (p.startsWith("/upload-session/") && req.method === "PUT") {
      const sess = ytSessions.get(Number(p.split("/").pop()));
      if (!sess) return send(res, 404, { error: { message: "no session" } });
      if (raw.length !== sess.length) return send(res, 400, { error: { message: `got ${raw.length} bytes, expected ${sess.length}` } });
      const vid = `vid${state.ytUploads.length + 1}`;
      state.ytUploads.push({ ...sess, bytes: raw.length, first: raw[1000], id: vid });
      // Unaudited API projects: YouTube locks uploads to private.
      return send(res, 200, { id: vid, status: { uploadStatus: "uploaded", privacyStatus: "private" } });
    }

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
    if (p === "/v25.0/me" && !url.searchParams.get("fields")?.includes("client_business_id")) return send(res, 200, { user_id: "1789", username: "chasemorrin_test" });

    // Unified login (Facebook Login for Business with a configuration)
    if (p === "/v25.0/oauth/access_token") {
      const q = url.searchParams;
      if (q.get("code") !== "good-code" || q.get("client_secret") !== "test-ig-secret" || q.get("client_id") !== "test-app") {
        return send(res, 400, { error: { message: "bad code" } });
      }
      return send(res, 200, { access_token: "suat-tok", token_type: "bearer" });
    }
    // Like Meta's real behaviour when the app and account share a business portfolio:
    // nothing in assigned accounts or token scopes; the account shows up on the business.
    if (p === "/v25.0/me/assigned_instagram_accounts") return send(res, 200, { data: [] });
    if (p === "/v25.0/debug_token") return send(res, 200, { data: { granular_scopes: [{ scope: "instagram_basic" }, { scope: "instagram_content_publish" }] } });
    if (p === "/v25.0/me" && url.searchParams.get("fields")?.includes("client_business_id")) return send(res, 200, { id: "sysuser1", client_business_id: "biz1" });
    if (p === "/v25.0/biz1/instagram_business_accounts") return send(res, 400, { error: { message: "Unsupported get request", code: 100 } });
    if (p === "/v25.0/biz1/owned_instagram_accounts") return send(res, 200, { data: [{ id: "1789", username: "chasemorrin_test" }] });
    if (p === "/v25.0/1789" && req.method === "GET") return send(res, 200, { id: "1789", username: "chasemorrin_test" });

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
