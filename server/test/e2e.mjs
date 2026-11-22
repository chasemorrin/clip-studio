// End-to-end test: runs the real server locally against fake Apple/Claude/Instagram/Google/YouTube services.
// Usage: node test/e2e.mjs
import { spawn, execSync } from "node:child_process";
import fs from "node:fs";
import assert from "node:assert/strict";
import { start, appleToken, state, containers, log } from "./mock-services.mjs";

const MOCK = 9911, PORT = 8799, BASE = `http://127.0.0.1:${PORT}`;
// UNIFIED=1 tests Meta's Unified login (Facebook Login for Business) instead of Instagram login.
const UNIFIED = process.env.UNIFIED === "1";
const env = { ...process.env, NO_PROXY: "127.0.0.1,localhost", no_proxy: "127.0.0.1,localhost", WRANGLER_SEND_METRICS: "false" };

fs.writeFileSync(".dev.vars", [
  "SESSION_SECRET=test-session-secret-0123456789",
  "ANTHROPIC_API_KEY=test-anthropic-key",
  "IG_APP_SECRET=test-ig-secret",
  "DEV_LOGIN_KEY=test-dev-key",
  `ANTHROPIC_BASE=http://127.0.0.1:${MOCK}`,
  `IG_GRAPH_BASE=http://127.0.0.1:${MOCK}`,
  `IG_OAUTH_BASE=http://127.0.0.1:${MOCK}`,
  `APPLE_KEYS_URL=http://127.0.0.1:${MOCK}/apple/keys`,
  `PUBLIC_URL=${BASE}`,
  "IG_APP_ID=test-ig-app",
  "CLAUDE_DAILY_LIMIT=3",
  `FB_GRAPH_BASE=http://127.0.0.1:${MOCK}`,
  "GOOGLE_CLIENT_ID=test-g-client",
  "GOOGLE_CLIENT_SECRET=test-g-secret",
  `GOOGLE_OAUTH_BASE=http://127.0.0.1:${MOCK}`,
  `YT_API_BASE=http://127.0.0.1:${MOCK}`,
  "CONTACT_EMAIL=test@example.com",
  // Always set explicitly, so the real value in wrangler.toml doesn't leak into tests.
  `IG_LOGIN_URL=${UNIFIED ? `https://www.facebook.com/v25.0/dialog/oauth?client_id=test-app&redirect_uri=${encodeURIComponent(BASE + "/instagram/callback")}&config_id=cfg123&response_type=code` : ""}`,
].join("\n"));

fs.rmSync(".wrangler/state", { recursive: true, force: true });
execSync("npx wrangler d1 migrations apply clip-studio --local", { env, stdio: "pipe" });
const mock = await start(MOCK);
const dev = spawn("npx", ["wrangler", "dev", "--local", "--port", String(PORT), "--test-scheduled", "--ip", "127.0.0.1"], { env, stdio: ["ignore", "pipe", "pipe"], detached: true });
let devOut = "";
dev.stdout.on("data", (d) => (devOut += d));
dev.stderr.on("data", (d) => (devOut += d));

const sql = (q) => execSync(`npx wrangler d1 execute clip-studio --local --json --command ${JSON.stringify(q)}`, { env, stdio: "pipe" }).toString();
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let token = "";
async function api(method, path, body, headers = {}) {
  const res = await fetch(BASE + path, {
    method,
    headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(body && !(body instanceof Uint8Array) ? { "content-type": "application/json" } : {}), ...headers },
    body: body instanceof Uint8Array ? body : body ? JSON.stringify(body) : undefined,
    redirect: "manual",
  });
  const text = await res.text();
  let json; try { json = JSON.parse(text); } catch { json = text; }
  return { status: res.status, json, headers: res.headers };
}
const tick = () => fetch(`${BASE}/__scheduled?cron=*/5+*+*+*+*`).then((r) => r.text()).then(() => sleep(400));
const results = [];
async function check(name, fn) {
  try { await fn(); results.push(`PASS  ${name}`); }
  catch (e) { results.push(`FAIL  ${name}\n      ${e.message}`); }
}

try {
  for (let i = 0; i < 60; i++) { try { await fetch(BASE + "/"); break; } catch { await sleep(500); } }

  await check("health", async () => assert.equal((await api("GET", "/")).json.ok, true));
  await check("homepage, privacy policy and terms for browsers mention YouTube and link to its terms", async () => {
    const home = await (await fetch(BASE + "/", { headers: { Accept: "text/html" } })).text();
    assert.match(home, /href="\/privacy"/); assert.match(home, /YouTube/); assert.match(home, /test@example\.com/);
    const priv = await (await fetch(BASE + "/privacy")).text();
    for (const must of ["YouTube API Services", "youtube.com/t/terms", "policies.google.com/privacy", "security.google.com/settings/security/permissions"]) {
      assert.ok(priv.includes(must), `privacy policy mentions ${must}`);
    }
    assert.match(await (await fetch(BASE + "/terms")).text(), /agree to be bound by the <a href="https:\/\/www\.youtube\.com\/t\/terms">YouTube Terms of Service/);
  });
  await check("rejects requests without sign-in", async () => assert.equal((await api("GET", "/v1/me")).status, 401));
  await check("test sign-in with wrong key is refused", async () => assert.equal((await api("POST", "/v1/auth/dev", { key: "nope" })).status, 403));
  await check("Sign in with Apple: valid token", async () => {
    const r = await api("POST", "/v1/auth/apple", { identityToken: appleToken() });
    assert.equal(r.status, 200); assert.match(r.json.token, /^v1\./);
  });
  await check("Sign in with Apple: wrong app is refused", async () => {
    assert.equal((await api("POST", "/v1/auth/apple", { identityToken: appleToken({ aud: "com.other.app" }) })).status, 401);
  });
  await check("Sign in with Apple: tampered token is refused", async () => {
    const t = appleToken(); const parts = t.split(".");
    const forged = Buffer.from(JSON.stringify({ iss: "https://appleid.apple.com", aud: "com.chasemorrin.clipstudio", sub: "attacker", exp: 9999999999 })).toString("base64url");
    assert.equal((await api("POST", "/v1/auth/apple", { identityToken: `${parts[0]}.${forged}.${parts[2]}` })).status, 401);
  });
  await check("test sign-in", async () => {
    const r = await api("POST", "/v1/auth/dev", { key: "test-dev-key" });
    assert.equal(r.status, 200); token = r.json.token;
  });
  await check("profile shows no Instagram yet", async () => assert.equal((await api("GET", "/v1/me")).json.instagram, null));

  // Upload a fake 2 MB clip.
  const clip = new Uint8Array(2 * 1024 * 1024).map((_, i) => i % 251);
  let clipKey = "";
  await check("upload a clip", async () => {
    const r = await api("PUT", "/v1/media", clip, { "content-type": "video/mp4" });
    assert.equal(r.status, 201, JSON.stringify(r.json)); clipKey = r.json.key;
  });
  await check("upload rejects other file types", async () => assert.equal((await api("PUT", "/v1/media", new Uint8Array(10), { "content-type": "text/plain" })).status, 415));
  await check("signed link downloads the exact file, supports ranges, rejects tampering", async () => {
    const { json } = await api("GET", `/v1/media-url/${clipKey}`);
    const full = new Uint8Array(await (await fetch(json.url)).arrayBuffer());
    assert.equal(full.length, clip.length); assert.equal(full[1000], clip[1000]);
    const part = await fetch(json.url, { headers: { Range: "bytes=100-199" } });
    assert.equal(part.status, 206); const pb = new Uint8Array(await part.arrayBuffer());
    assert.equal(pb.length, 100); assert.equal(pb[0], clip[100]);
    assert.equal((await fetch(json.url.replace(/sig=.{4}/, "sig=AAAA"))).status, 403);
  });

  // Planner items.
  let ideaId = "";
  await check("create, edit and list planner items", async () => {
    let r = await api("POST", "/v1/items", { title: "Body and Soul, one take", pillar: "standards", format: "reel", status: "idea" });
    assert.equal(r.status, 201); ideaId = r.json.item.id;
    r = await api("PATCH", `/v1/items/${ideaId}`, { date: "2026-11-20", status: "planned", notes: "side angle" });
    assert.equal(r.json.item.date, "2026-11-20"); assert.equal(r.json.item.status, "planned");
    r = await api("GET", "/v1/items"); assert.equal(r.json.items.length, 1);
  });
  await check("can't attach someone else's file", async () => {
    assert.equal((await api("PATCH", `/v1/items/${ideaId}`, { media: [{ key: "u_other/x.mp4", type: "video" }] })).status, 400);
  });
  await check("auto-post needs a time and a file", async () => {
    assert.equal((await api("PATCH", `/v1/items/${ideaId}`, { autoPost: true })).status, 400);
  });

  // Instagram connection.
  await check("connect Instagram", async () => {
    const r = await api("GET", "/v1/instagram/connect");
    const u = new URL(r.json.url);
    if (UNIFIED) {
      assert.equal(u.hostname, "www.facebook.com"); assert.equal(u.searchParams.get("config_id"), "cfg123"); assert.ok(u.searchParams.get("state"));
    } else {
      assert.equal(u.hostname, "www.instagram.com"); assert.match(u.searchParams.get("scope"), /instagram_business_content_publish/);
    }
    const cb = await api("GET", `/instagram/callback?code=good-code%23_&state=${u.searchParams.get("state")}`);
    assert.equal(cb.status, 302); const loc = cb.headers.get("location");
    assert.match(loc, /^clipstudio:\/\/instagram\?status=connected&username=chasemorrin_test/, loc);
    assert.equal((await api("GET", "/v1/me")).json.instagram.username, "chasemorrin_test");
  });
  await check("connect with a pasted access token", async () => {
    assert.equal((await api("POST", "/v1/instagram/token", { token: "short" })).status, 400);
    const r = await api("POST", "/v1/instagram/token", { token: "IGAA-pasted-token-from-dashboard-123456" });
    assert.equal(r.status, 200, JSON.stringify(r.json)); assert.equal(r.json.username, "chasemorrin_test");
    assert.equal((await api("GET", "/v1/me")).json.instagram.username, "chasemorrin_test");
  });
  await check("reused Instagram login link is refused", async () => {
    const r = await api("GET", "/v1/instagram/connect"); const st = new URL(r.json.url).searchParams.get("state");
    await api("GET", `/instagram/callback?code=good-code&state=${st}`);
    const again = await api("GET", `/instagram/callback?code=good-code&state=${st}`);
    assert.match(again.headers.get("location"), /status=error/);
  });

  // Auto-post a reel.
  let reelId = "";
  await check("schedule a reel and publish it on the timer", async () => {
    const past = Math.floor(Date.now() / 1000) - 60;
    let r = await api("POST", "/v1/items", { title: "Solo, live", format: "reel", date: "2026-11-14", status: "edited", caption: "Live at [venue]", media: [{ key: clipKey, type: "video" }], coverMs: 1500, publishAt: past, autoPost: true });
    assert.equal(r.status, 201, JSON.stringify(r.json)); reelId = r.json.item.id; assert.equal(r.json.item.postState, "queued");
    await tick();
    r = await api("GET", "/v1/items"); let it = r.json.items.find((x) => x.id === reelId);
    assert.equal(it.postState, "publishing", JSON.stringify(it));
    const c = [...containers.values()].at(-1);
    assert.equal(c.params.media_type, "REELS"); assert.equal(c.params.thumb_offset, "1500"); assert.equal(c.params.share_to_feed, "true");
    assert.equal(c.fetched.bytes, clip.length, "Instagram could download the full clip");
    await tick(); // IN_PROGRESS
    it = (await api("GET", "/v1/items")).json.items.find((x) => x.id === reelId); assert.equal(it.postState, "publishing");
    await tick(); // FINISHED -> publish
    it = (await api("GET", "/v1/items")).json.items.find((x) => x.id === reelId);
    assert.equal(it.postState, "posted", JSON.stringify(it)); assert.equal(it.status, "posted");
    assert.match(it.permalink, /instagram\.com\/reel\//);
    assert.equal((await api("GET", `/v1/media-url/${clipKey}`)).status, 404, "file deleted after posting");
  });
  await check("post now starts publishing right away", async () => {
    const k = (await api("PUT", "/v1/media", new Uint8Array(8000), { "content-type": "video/mp4" })).json.key;
    const later = Math.floor(Date.now() / 1000) + 86400;
    const r = await api("POST", "/v1/items", { title: "Now", format: "reel", media: [{ key: k, type: "video" }], publishAt: later, autoPost: true });
    const pn = await api("POST", `/v1/items/${r.json.item.id}/publish-now`);
    assert.equal(pn.status, 200, JSON.stringify(pn.json));
    await sleep(1500);
    const it = (await api("GET", "/v1/items")).json.items.find((x) => x.id === r.json.item.id);
    assert.ok(["publishing", "posted"].includes(it.postState), JSON.stringify(it));
    await tick(); await tick();
    assert.equal((await api("GET", "/v1/items")).json.items.find((x) => x.id === it.id).postState, "posted");
  });
  await check("future posts wait for their time", async () => {
    const k = (await api("PUT", "/v1/media", new Uint8Array(5000), { "content-type": "video/mp4" })).json.key;
    const future = Math.floor(Date.now() / 1000) + 3600;
    const r = await api("POST", "/v1/items", { title: "Later", format: "reel", media: [{ key: k, type: "video" }], publishAt: future, autoPost: true });
    await tick();
    const it = (await api("GET", "/v1/items")).json.items.find((x) => x.id === r.json.item.id);
    assert.equal(it.postState, "queued");
    await api("PATCH", `/v1/items/${it.id}`, { autoPost: false });
    assert.equal((await api("GET", "/v1/items")).json.items.find((x) => x.id === it.id).postState, null);
  });
  await check("carousel of two photos", async () => {
    const a = (await api("PUT", "/v1/media", new Uint8Array(3000), { "content-type": "image/jpeg" })).json;
    const b = (await api("PUT", "/v1/media", new Uint8Array(3000), { "content-type": "image/jpeg" })).json;
    const r = await api("POST", "/v1/items", { title: "Gig photos", format: "carousel", caption: "Thank you [venue]", media: [a, b], publishAt: 1, autoPost: true });
    await tick(); let it = (await api("GET", "/v1/items")).json.items.find((x) => x.id === r.json.item.id);
    assert.equal(it.postState, "children", JSON.stringify(it));
    await tick(); it = (await api("GET", "/v1/items")).json.items.find((x) => x.id === r.json.item.id);
    assert.equal(it.postState, "publishing", JSON.stringify(it));
    await tick(); await tick(); it = (await api("GET", "/v1/items")).json.items.find((x) => x.id === r.json.item.id);
    assert.equal(it.postState, "posted", JSON.stringify(it));
  });
  await check("a video Instagram rejects shows a clear error and can be retried", async () => {
    const k = (await api("PUT", "/v1/media", new Uint8Array(5000), { "content-type": "video/mp4" })).json.key;
    state.failNextContainer = true;
    const r = await api("POST", "/v1/items", { title: "Bad file", format: "reel", media: [{ key: k, type: "video" }], publishAt: 1, autoPost: true });
    await tick(); await tick();
    let it = (await api("GET", "/v1/items")).json.items.find((x) => x.id === r.json.item.id);
    assert.equal(it.postState, "failed"); assert.match(it.postError, /couldn't process/);
    const rr = await api("POST", `/v1/items/${it.id}/retry`); assert.equal(rr.json.item.postState, "queued");
  });
  await check("expiring Instagram token gets refreshed by the timer", async () => {
    const now = Math.floor(Date.now() / 1000);
    sql(`UPDATE ig_accounts SET token_issued_at=${now - 50 * 86400}, expires_at=${now + 5 * 86400}`);
    await tick();
    const out = sql("SELECT access_token, expires_at FROM ig_accounts");
    // Unified login tokens don't expire, so they're left alone.
    assert.match(out, UNIFIED ? /suat-tok/ : /long-tok-refreshed/);
  });

  // YouTube.
  const itemById = async (id) => (await api("GET", "/v1/items")).json.items.find((x) => x.id === id);
  const clipOf = async (n) => {
    const bytes = new Uint8Array(n).map((_, i) => (i * 7) % 253);
    return { bytes, key: (await api("PUT", "/v1/media", bytes, { "content-type": "video/mp4" })).json.key };
  };
  await check("profile shows YouTube is available but not connected", async () => {
    const me = (await api("GET", "/v1/me")).json;
    assert.equal(me.youtube, null); assert.equal(me.youtubeAvailable, true);
  });
  await check("scheduling to YouTube before connecting fails clearly", async () => {
    const { key } = await clipOf(4000);
    const r = await api("POST", "/v1/items", { title: "Early", format: "reel", media: [{ key, type: "video" }], publishAt: 1, youtube: true });
    assert.equal(r.json.item.youtube.state, "queued");
    await tick();
    const it = await itemById(r.json.item.id);
    assert.equal(it.youtube.state, "failed"); assert.match(it.youtube.error, /Connect YouTube/);
    await api("DELETE", `/v1/items/${it.id}`);
  });
  await check("connect YouTube", async () => {
    const r = await api("GET", "/v1/youtube/connect");
    const u = new URL(r.json.url);
    assert.equal(u.hostname, "accounts.google.com");
    assert.match(u.searchParams.get("scope"), /youtube\.upload/); assert.equal(u.searchParams.get("access_type"), "offline");
    assert.equal(u.searchParams.get("redirect_uri"), `${BASE}/youtube/callback`);
    const st = u.searchParams.get("state"); assert.match(st, /^y_/);
    const cb = await api("GET", `/youtube/callback?code=good-g-code&state=${st}`);
    assert.equal(cb.status, 302); assert.match(cb.headers.get("location"), /^clipstudio:\/\/youtube\?status=connected&channel=Chase\+Morrin/);
    const me = (await api("GET", "/v1/me")).json;
    assert.equal(me.youtube.channelTitle, "Chase Morrin"); assert.equal(me.youtube.handle, "@chasemorrin");
  });
  await check("YouTube login can't be replayed or used at the Instagram callback", async () => {
    const st = new URL((await api("GET", "/v1/youtube/connect")).json.url).searchParams.get("state");
    assert.match((await api("GET", `/instagram/callback?code=good-code&state=${st}`)).headers.get("location"), /status=error/);
    const r = await api("GET", "/v1/youtube/connect"); const st2 = new URL(r.json.url).searchParams.get("state");
    await api("GET", `/youtube/callback?code=good-g-code&state=${st2}`);
    assert.match((await api("GET", `/youtube/callback?code=good-g-code&state=${st2}`)).headers.get("location"), /status=error/);
    assert.match((await api("GET", `/youtube/callback?error=access_denied&state=x`)).headers.get("location"), /status=cancelled/);
  });
  await check("YouTube is refused for photos", async () => {
    const a = (await api("PUT", "/v1/media", new Uint8Array(3000), { "content-type": "image/jpeg" })).json;
    const r = await api("POST", "/v1/items", { title: "Photo", format: "photo", media: [a], publishAt: 1, youtube: true });
    assert.equal(r.status, 400); assert.match(r.json.error.message, /needs a video/);
  });
  await check("a clip posts to Instagram and YouTube; the file is kept until both are done", async () => {
    const { bytes, key } = await clipOf(1_500_000);
    const r = await api("POST", "/v1/items", { title: "Solo, live", ytTitle: "Body and Soul solo <live> #Shorts", caption: "Live at the club", format: "reel",
      media: [{ key, type: "video" }], publishAt: Math.floor(Date.now() / 1000) - 30, autoPost: true, youtube: true });
    assert.equal(r.status, 201, JSON.stringify(r.json));
    const id = r.json.item.id;
    state.ytFailNext = 3; // YouTube is down for a bit: Instagram finishes first
    await tick(); // IG -> publishing; YT fails (retry 1)
    let it = await itemById(id);
    assert.equal(it.youtube.state, "queued"); assert.match(it.youtube.error, /^Retrying/);
    await tick(); await tick(); // IG posted; YT retries 2 and 3
    it = await itemById(id);
    assert.equal(it.postState, "posted", JSON.stringify(it));
    assert.equal(it.media.length, 1, "file kept for YouTube");
    assert.equal((await api("GET", `/v1/media-url/${key}`)).status, 200);
    await tick(); // YT uploads
    it = await itemById(id);
    assert.equal(it.youtube.state, "posted", JSON.stringify(it)); assert.equal(it.youtube.error, null);
    assert.equal(it.youtube.privacy, "private"); assert.match(it.youtube.url, /youtube\.com\/shorts\/vid/);
    const up = state.ytUploads.at(-1);
    assert.equal(up.bytes, bytes.length, "the whole file streamed to YouTube"); assert.equal(up.first, bytes[1000]);
    assert.equal(up.meta.snippet.title, "Body and Soul solo live #Shorts"); assert.equal(up.meta.snippet.description, "Live at the club");
    assert.equal(up.meta.snippet.categoryId, "10"); assert.equal(up.meta.status.privacyStatus, "public");
    assert.equal(up.meta.status.selfDeclaredMadeForKids, false); assert.equal(up.type, "video/mp4");
    assert.equal(it.media.length, 0, "file deleted once both are done");
    assert.equal((await api("GET", `/v1/media-url/${key}`)).status, 404);
  });
  await check("YouTube-only post refreshes the expired access token and keeps the file", async () => {
    sql("UPDATE yt_accounts SET access_expires_at = 0");
    const { key } = await clipOf(6000);
    const r = await api("POST", "/v1/items", { title: "YT only", format: "reel", media: [{ key, type: "video" }], publishAt: 1, youtube: true });
    await tick();
    const it = await itemById(r.json.item.id);
    assert.equal(it.youtube.state, "posted", JSON.stringify(it)); assert.equal(it.postState, null);
    assert.equal(state.ytUploads.at(-1).bearer, "ya29-2"); assert.match(sql("SELECT access_token FROM yt_accounts"), /ya29-2/);
    assert.equal(it.media.length, 1, "Instagram might still be switched on later");
    const again = await api("PATCH", `/v1/items/${it.id}`, { youtube: false });
    assert.equal(again.json.item.youtube.state, "posted", "can't un-post");
  });
  await check("future YouTube posts wait; switching YouTube off cancels", async () => {
    const { key } = await clipOf(5000);
    const r = await api("POST", "/v1/items", { title: "Later", format: "reel", media: [{ key, type: "video" }], publishAt: Math.floor(Date.now() / 1000) + 3600, youtube: true });
    const n = state.ytUploads.length;
    await tick();
    assert.equal((await itemById(r.json.item.id)).youtube.state, "queued"); assert.equal(state.ytUploads.length, n);
    const off = await api("PATCH", `/v1/items/${r.json.item.id}`, { youtube: false });
    assert.equal(off.json.item.youtube.state, null);
  });
  await check("post now sends to YouTube only when asked", async () => {
    const { key } = await clipOf(5000);
    const r = await api("POST", "/v1/items", { title: "Now YT", format: "reel", media: [{ key, type: "video" }], publishAt: Math.floor(Date.now() / 1000) + 86400 });
    const pn = await api("POST", `/v1/items/${r.json.item.id}/publish-now`, { instagram: false, youtube: true });
    assert.equal(pn.status, 200, JSON.stringify(pn.json)); assert.equal(pn.json.item.postState, null);
    await sleep(1500); await tick();
    const it = await itemById(r.json.item.id);
    assert.equal(it.youtube.state, "posted", JSON.stringify(it)); assert.equal(it.postState, null);
  });
  await check("a revoked Google login fails with a reconnect message and can be retried", async () => {
    sql("UPDATE yt_accounts SET access_expires_at = 0, refresh_token = 'revoked'");
    const { key } = await clipOf(5000);
    const r = await api("POST", "/v1/items", { title: "Revoked", format: "reel", media: [{ key, type: "video" }], publishAt: 1, youtube: true });
    await tick();
    let it = await itemById(r.json.item.id);
    assert.equal(it.youtube.state, "failed"); assert.match(it.youtube.error, /Reconnect YouTube/);
    sql("UPDATE yt_accounts SET refresh_token = '1//refresh-1'");
    const rr = await api("POST", `/v1/items/${it.id}/retry`); assert.equal(rr.json.item.youtube.state, "queued");
    await tick();
    assert.equal((await itemById(it.id)).youtube.state, "posted");
  });
  await check("an interrupted upload is marked failed, not uploaded twice", async () => {
    const { key } = await clipOf(5000);
    const r = await api("POST", "/v1/items", { title: "Stuck", format: "reel", media: [{ key, type: "video" }], publishAt: 1 });
    sql(`UPDATE items SET yt_state='uploading', yt_started_at=${Math.floor(Date.now() / 1000) - 3600} WHERE id='${r.json.item.id}'`);
    assert.equal((await api("DELETE", `/v1/items/${r.json.item.id}`)).status, 409);
    await tick();
    const it = await itemById(r.json.item.id);
    assert.equal(it.youtube.state, "failed"); assert.match(it.youtube.error, /interrupted/);
  });
  await check("disconnect YouTube revokes access with Google", async () => {
    assert.equal((await api("POST", "/v1/youtube/disconnect")).json.disconnected, true);
    assert.equal((await api("GET", "/v1/me")).json.youtube, null);
    assert.equal(state.ytRevoked.at(-1), "1//refresh-1");
    // Connect again so account deletion is tested with a channel connected.
    const st = new URL((await api("GET", "/v1/youtube/connect")).json.url).searchParams.get("state");
    await api("GET", `/youtube/callback?code=good-g-code&state=${st}`);
  });

  // Claude.
  await check("Claude passthrough uses the server's model and caps tokens", async () => {
    const r = await api("POST", "/v1/claude", { system: "be brief", messages: [{ role: "user", content: "hello" }], maxTokens: 99999 });
    assert.equal(r.status, 200, JSON.stringify(r.json)); assert.equal(r.json.text, "echo:hello");
    const sent = state.claudeBodies.at(-1);
    assert.equal(sent.model, "claude-sonnet-5-5"); assert.equal(sent.max_tokens, 4000); assert.equal(sent.system, "be brief");
  });
  await check("Claude daily limit", async () => {
    await api("POST", "/v1/claude", { messages: [{ role: "user", content: "2" }] });
    await api("POST", "/v1/claude", { messages: [{ role: "user", content: "3" }] });
    const r = await api("POST", "/v1/claude", { messages: [{ role: "user", content: "4" }] });
    assert.equal(r.status, 429); assert.match(r.json.error.message, /today's limit/);
  });

  await check("Meta deauthorize and data-deletion callbacks verify the signature and remove the connection", async () => {
    const crypto = await import("node:crypto");
    const payload = Buffer.from(JSON.stringify({ algorithm: "HMAC-SHA256", user_id: "1789" })).toString("base64url");
    const sig = crypto.createHmac("sha256", "test-ig-secret").update(payload).digest("base64url");
    const bad = await fetch(BASE + "/instagram/deauthorize", { method: "POST", body: new URLSearchParams({ signed_request: `AAAA.${payload}` }) });
    assert.equal(bad.status, 400);
    const r = await fetch(BASE + "/instagram/data-deletion", { method: "POST", body: new URLSearchParams({ signed_request: `${sig}.${payload}` }) });
    const j = await r.json();
    assert.match(j.confirmation_code, /^del_/); assert.match(j.url, /deletion-status/);
    assert.equal((await api("GET", "/v1/me")).json.instagram, null);
  });
  await check("delete account removes everything", async () => {
    assert.equal((await api("DELETE", "/v1/me")).json.deleted, true);
    assert.match(sql("SELECT COUNT(*) AS n FROM items"), /"n": 0/);
    assert.match(sql("SELECT COUNT(*) AS n FROM media"), /"n": 0/);
    assert.match(sql("SELECT COUNT(*) AS n FROM yt_accounts"), /"n": 0/);
    assert.equal(state.ytRevoked.length, 2, "YouTube access revoked on account deletion");
  });
} finally {
  console.log(results.join("\n"));
  const failed = results.filter((r) => r.startsWith("FAIL")).length;
  console.log(`\n${results.length - failed} passed, ${failed} failed`);
  if (failed) console.log("\n--- server log (tail) ---\n" + devOut.split("\n").slice(-40).join("\n"));
  console.log(UNIFIED ? "(mode: Unified login)" : "(mode: Instagram login)");
  try { process.kill(-dev.pid, "SIGTERM"); } catch { dev.kill("SIGTERM"); } // stop wrangler and its workerd child
  mock.close();
  setTimeout(() => process.exit(failed ? 1 : 0), 300);
}
