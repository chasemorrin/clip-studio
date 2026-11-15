import { Hono } from "hono";
import { Env, HttpError, b64urlDecode, hmac, hmacVerify, newId, nowSec, signedMediaUrl } from "./util";
import { createSession, readSession, userForAppleSub, verifyAppleToken } from "./auth";
import { finishConnect, startConnect } from "./instagram";
import { runPublisher } from "./publisher";

type Vars = { uid: string };
const app = new Hono<{ Bindings: Env; Variables: Vars }>();

app.onError((err, c) => {
  if (err instanceof HttpError) return c.json({ error: { code: err.code, message: err.message } }, err.status as any);
  console.log("unhandled", err);
  return c.json({ error: { code: "server_error", message: "Something went wrong on the server. Try again." } }, 500);
});

app.get("/", (c) => c.json({ ok: true, name: "clip-studio" }));

const page = (title: string, body: string) => `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>${title} · Clip Studio</title>
<style>body{font:16px/1.6 -apple-system,system-ui,sans-serif;max-width:680px;margin:40px auto;padding:0 20px;color:#1c1c1e}
h1{font-size:28px}h2{font-size:18px;margin-top:28px}@media(prefers-color-scheme:dark){body{background:#111;color:#eee}}</style>
</head><body>${body}</body></html>`;

app.get("/privacy", (c) => c.html(page("Privacy policy", `
<h1>Clip Studio privacy policy</h1>
<p>Last updated November 15, 2026.</p>
<p>Clip Studio helps musicians find short clips in their own performance videos, plan posts and publish them to their own Instagram account.</p>
<h2>What we store</h2>
<ul>
<li>Your account: an anonymous ID from Sign in with Apple.</li>
<li>Your posting calendar: titles, captions, dates and notes you enter.</li>
<li>Clips you choose to schedule, only until they're posted. They're deleted from our storage after posting.</li>
<li>Your Instagram connection: the account ID, username and access token Meta provides, used only to publish the posts you schedule.</li>
</ul>
<h2>What we don't do</h2>
<ul>
<li>Your full videos stay on your phone. The app analyzes them on the device.</li>
<li>We don't sell or share your data, run ads, or use it to track you.</li>
<li>We don't read your Instagram messages, comments or followers.</li>
</ul>
<h2>Claude</h2>
<p>When you ask Claude (by Anthropic) to suggest clips or write captions, a few still frames, an audio summary and your description of your music are sent to Anthropic's API to produce the answer.</p>
<h2>Deleting your data</h2>
<p>In the app, open Settings and choose Delete account and data. This removes everything above from our servers. Removing Clip Studio from your Meta or Instagram settings also deletes the Instagram connection.</p>
<h2>Contact</h2>
<p>Questions: use the contact details on the Clip Studio listing.</p>`)));

app.get("/terms", (c) => c.html(page("Terms", `
<h1>Clip Studio terms</h1>
<p>Use Clip Studio only with videos and music you have the right to post. You're responsible for what you publish to your Instagram account. The service is provided as is, without warranty.</p>`)));

/* ---------- sign in ---------- */

app.post("/v1/auth/apple", async (c) => {
  const { identityToken } = await c.req.json<{ identityToken: string }>();
  const sub = await verifyAppleToken(c.env, identityToken || "");
  const uid = await userForAppleSub(c.env, sub);
  return c.json({ token: await createSession(c.env, uid), userId: uid });
});

// Lets you test before Sign in with Apple is set up. Only works when DEV_LOGIN_KEY is set.
app.post("/v1/auth/dev", async (c) => {
  const { key } = await c.req.json<{ key: string }>();
  if (!c.env.DEV_LOGIN_KEY) throw new HttpError(403, "forbidden", "Test sign-in is turned off. Set the DEV_LOGIN_KEY secret to use it.");
  if (key !== c.env.DEV_LOGIN_KEY) throw new HttpError(403, "wrong_password", "That test password is wrong.");
  const uid = await userForAppleSub(c.env, "dev");
  return c.json({ token: await createSession(c.env, uid), userId: uid });
});

app.use("/v1/*", async (c, next) => {
  if (c.req.path.startsWith("/v1/auth/")) return next();
  c.set("uid", await readSession(c.env, c.req.header("Authorization")));
  await next();
});

app.get("/v1/me", async (c) => {
  const uid = c.get("uid");
  const ig = await c.env.DB.prepare("SELECT username, expires_at FROM ig_accounts WHERE user_id = ?").bind(uid).first<{ username: string; expires_at: number }>();
  const u = await c.env.DB.prepare("SELECT claude_day, claude_count FROM users WHERE id = ?").bind(uid).first<{ claude_day: string; claude_count: number }>();
  const today = new Date().toISOString().slice(0, 10);
  return c.json({
    userId: uid,
    instagram: ig ? { username: ig.username, expiresAt: ig.expires_at, expired: ig.expires_at < nowSec() } : null,
    claude: { usedToday: u?.claude_day === today ? u.claude_count : 0, dailyLimit: Number(c.env.CLAUDE_DAILY_LIMIT) },
  });
});

// Required by the App Store: delete the account and everything stored with it.
app.delete("/v1/me", async (c) => {
  const uid = c.get("uid");
  const { results } = await c.env.DB.prepare("SELECT key FROM media WHERE user_id = ?").bind(uid).all<{ key: string }>();
  for (const r of results) await c.env.MEDIA.delete(r.key);
  for (const t of ["media", "items", "ig_accounts", "oauth_states"]) {
    await c.env.DB.prepare(`DELETE FROM ${t} WHERE user_id = ?`).bind(uid).run();
  }
  await c.env.DB.prepare("DELETE FROM users WHERE id = ?").bind(uid).run();
  return c.json({ deleted: true });
});

/* ---------- planner items ---------- */

interface ItemRow {
  id: string; title: string; pillar: string; format: string; date: string; status: string; notes: string; plan: string | null;
  caption: string; media: string; cover_ms: number | null; publish_at: number | null; post_state: string | null;
  ig_media_id: string | null; ig_permalink: string | null; post_error: string | null; created_at: number; updated_at: number;
}

const toJson = (r: ItemRow) => ({
  id: r.id, title: r.title, pillar: r.pillar, format: r.format, date: r.date, status: r.status, notes: r.notes,
  plan: r.plan ? JSON.parse(r.plan) : null, caption: r.caption, media: JSON.parse(r.media || "[]"), coverMs: r.cover_ms,
  publishAt: r.publish_at, postState: r.post_state, instagramMediaId: r.ig_media_id, permalink: r.ig_permalink,
  postError: r.post_error, createdAt: r.created_at, updatedAt: r.updated_at,
});

const STATUSES = ["idea", "planned", "filmed", "edited", "posted"];
const FORMATS = ["reel", "carousel", "photo"];

async function applyFields(env: Env, uid: string, body: any, current: ItemRow | null) {
  const f: Record<string, unknown> = {};
  const str = (k: string, max: number) => { if (typeof body[k] === "string") f[k] = body[k].slice(0, max); };
  str("title", 300); str("pillar", 40); str("notes", 5000); str("caption", 2200);
  if (typeof body.date === "string") f.date = /^\d{4}-\d{2}-\d{2}$/.test(body.date) ? body.date : "";
  if (STATUSES.includes(body.status)) f.status = body.status;
  if (FORMATS.includes(body.format)) f.format = body.format;
  if ("plan" in body) f.plan = body.plan == null ? null : JSON.stringify(body.plan).slice(0, 100_000);
  if ("coverMs" in body) f.cover_ms = Number.isFinite(body.coverMs) ? Math.max(0, Math.round(body.coverMs)) : null;
  if (Array.isArray(body.media)) {
    const media = body.media.slice(0, 10).map((m: any) => ({ key: String(m.key), type: m.type === "image" ? "image" : "video" }));
    for (const m of media) {
      const own = await env.DB.prepare("SELECT 1 FROM media WHERE key = ? AND user_id = ?").bind(m.key, uid).first();
      if (!own) throw new HttpError(400, "bad_media", "One of the attached files wasn't found. Upload it again.");
    }
    f.media = JSON.stringify(media);
  }
  if ("publishAt" in body) f.publish_at = Number.isFinite(body.publishAt) ? Math.round(body.publishAt) : null;

  // Auto-posting: the app sends autoPost true/false.
  const busy = current?.post_state === "children" || current?.post_state === "publishing";
  if ("autoPost" in body) {
    if (busy) throw new HttpError(409, "publishing", "This post is being published right now. Wait a few minutes.");
    if (current?.post_state === "posted") throw new HttpError(409, "posted", "This post is already on Instagram.");
    if (body.autoPost) {
      const publishAt = (f.publish_at as number | null | undefined) ?? current?.publish_at;
      const media = JSON.parse((f.media as string) ?? current?.media ?? "[]");
      if (!publishAt) throw new HttpError(400, "no_time", "Pick a date and time to post.");
      if (!media.length) throw new HttpError(400, "no_media", "Attach a clip or photo before scheduling it to post.");
      f.post_state = "queued"; f.post_error = null; f.post_attempts = 0; f.ig_container_id = null; f.ig_children = null;
    } else {
      f.post_state = null; f.post_error = null;
    }
  } else if (busy && ("media" in f || "caption" in f || "publish_at" in f)) {
    throw new HttpError(409, "publishing", "This post is being published right now. Wait a few minutes.");
  }
  return f;
}

async function getItem(env: Env, uid: string, id: string) {
  return env.DB.prepare("SELECT * FROM items WHERE id = ? AND user_id = ?").bind(id, uid).first<ItemRow>();
}

app.get("/v1/items", async (c) => {
  const since = Number(c.req.query("since") || 0);
  const { results } = await c.env.DB.prepare("SELECT * FROM items WHERE user_id = ? AND updated_at >= ? ORDER BY date, created_at")
    .bind(c.get("uid"), since).all<ItemRow>();
  return c.json({ items: results.map(toJson), serverTime: nowSec() });
});

app.post("/v1/items", async (c) => {
  const uid = c.get("uid");
  const body = await c.req.json();
  const id = typeof body.id === "string" && /^[\w-]{6,64}$/.test(body.id) ? body.id : newId("i_");
  if (await c.env.DB.prepare("SELECT 1 FROM items WHERE id = ?").bind(id).first()) throw new HttpError(409, "exists", "That item already exists.");
  const f = await applyFields(c.env, uid, body, null);
  const now = nowSec();
  const cols = ["id", "user_id", "created_at", "updated_at", ...Object.keys(f)];
  await c.env.DB.prepare(`INSERT INTO items (${cols.join(",")}) VALUES (${cols.map(() => "?").join(",")})`)
    .bind(id, uid, now, now, ...Object.values(f).map((v) => v ?? null)).run();
  return c.json({ item: toJson((await getItem(c.env, uid, id))!) }, 201);
});

app.patch("/v1/items/:id", async (c) => {
  const uid = c.get("uid");
  const current = await getItem(c.env, uid, c.req.param("id"));
  if (!current) throw new HttpError(404, "not_found", "That item doesn't exist anymore.");
  const f = await applyFields(c.env, uid, await c.req.json(), current);
  if (Object.keys(f).length) {
    await c.env.DB.prepare(`UPDATE items SET ${Object.keys(f).map((k) => `${k} = ?`).join(", ")}, updated_at = ? WHERE id = ? AND user_id = ?`)
      .bind(...Object.values(f).map((v) => v ?? null), nowSec(), current.id, uid).run();
  }
  return c.json({ item: toJson((await getItem(c.env, uid, current.id))!) });
});

app.delete("/v1/items/:id", async (c) => {
  const uid = c.get("uid");
  const current = await getItem(c.env, uid, c.req.param("id"));
  if (!current) return c.json({ deleted: true });
  if (current.post_state === "children" || current.post_state === "publishing") {
    throw new HttpError(409, "publishing", "This post is being published right now. Wait a few minutes.");
  }
  await c.env.DB.prepare("DELETE FROM items WHERE id = ? AND user_id = ?").bind(current.id, uid).run();
  return c.json({ deleted: true });
});

/* ---------- clips and photos ---------- */

const TYPES: Record<string, string> = { "video/mp4": "mp4", "video/quicktime": "mov", "image/jpeg": "jpg" };
// Cloudflare's free plan accepts request bodies up to 100 MB.
const MAX_UPLOAD = 95 * 1024 * 1024;

app.put("/v1/media", async (c) => {
  const uid = c.get("uid");
  const type = (c.req.header("Content-Type") || "").split(";")[0].trim();
  const ext = TYPES[type];
  if (!ext) throw new HttpError(415, "bad_type", "Upload an MP4 or MOV video, or a JPEG photo.");
  const size = Number(c.req.header("Content-Length") || 0);
  if (!size) throw new HttpError(411, "no_length", "The upload is missing its size.");
  if (size > MAX_UPLOAD) throw new HttpError(413, "too_big", "That file is over 95 MB, too big to upload. Shorten the clip and try again.");
  const key = `${uid}/${newId()}.${ext}`;
  await c.env.MEDIA.put(key, c.req.raw.body!, { httpMetadata: { contentType: type } });
  await c.env.DB.prepare("INSERT INTO media (key, user_id, content_type, size, created_at) VALUES (?, ?, ?, ?, ?)")
    .bind(key, uid, type, size, nowSec()).run();
  return c.json({ key, type: type.startsWith("image") ? "image" : "video", size }, 201);
});

app.delete("/v1/media/:key{.+}", async (c) => {
  const uid = c.get("uid");
  const key = c.req.param("key");
  const own = await c.env.DB.prepare("SELECT 1 FROM media WHERE key = ? AND user_id = ?").bind(key, uid).first();
  if (own) {
    await c.env.MEDIA.delete(key);
    await c.env.DB.prepare("DELETE FROM media WHERE key = ?").bind(key).run();
  }
  return c.json({ deleted: true });
});

// A preview link for the app (also shows signing works).
app.get("/v1/media-url/:key{.+}", async (c) => {
  const uid = c.get("uid");
  const key = c.req.param("key");
  const own = await c.env.DB.prepare("SELECT 1 FROM media WHERE key = ? AND user_id = ?").bind(key, uid).first();
  if (!own) throw new HttpError(404, "not_found", "That file doesn't exist anymore.");
  return c.json({ url: await signedMediaUrl(c.env, key, 3600) });
});

// Public but signed and time-limited: this is the link Instagram downloads from.
app.on(["GET", "HEAD"], "/m/:key{.+}", async (c) => {
  const key = decodeURIComponent(c.req.param("key"));
  const exp = Number(c.req.query("exp") || 0);
  const sig = c.req.query("sig") || "";
  if (exp < nowSec() || !(await hmacVerify(c.env.SESSION_SECRET, `media:${key}:${exp}`, sig))) return c.text("Link expired", 403);

  const range = c.req.header("Range");
  const m = range?.match(/^bytes=(\d*)-(\d*)$/);
  const head = await c.env.MEDIA.head(key);
  if (!head) return c.text("Not found", 404);
  const headers = new Headers({ "Content-Type": head.httpMetadata?.contentType || "application/octet-stream", "Accept-Ranges": "bytes", "Cache-Control": "private, max-age=600" });
  if (c.req.method === "HEAD") { headers.set("Content-Length", String(head.size)); return new Response(null, { headers }); }
  if (m && (m[1] || m[2])) {
    const start = m[1] ? Number(m[1]) : Math.max(0, head.size - Number(m[2]));
    const end = m[1] && m[2] ? Math.min(Number(m[2]), head.size - 1) : head.size - 1;
    if (start > end || start >= head.size) return new Response(null, { status: 416, headers: { "Content-Range": `bytes */${head.size}` } });
    const obj = await c.env.MEDIA.get(key, { range: { offset: start, length: end - start + 1 } });
    headers.set("Content-Range", `bytes ${start}-${end}/${head.size}`);
    headers.set("Content-Length", String(end - start + 1));
    return new Response(obj!.body, { status: 206, headers });
  }
  const obj = await c.env.MEDIA.get(key);
  headers.set("Content-Length", String(head.size));
  return new Response(obj!.body, { headers });
});

/* ---------- Claude ---------- */

app.post("/v1/claude", async (c) => {
  const uid = c.get("uid");
  const body = await c.req.json<{ system?: string; messages: unknown[]; maxTokens?: number; temperature?: number }>();
  if (!Array.isArray(body.messages) || !body.messages.length) throw new HttpError(400, "bad_request", "Nothing to send to Claude.");
  const today = new Date().toISOString().slice(0, 10);
  const u = await c.env.DB.prepare("SELECT claude_day, claude_count FROM users WHERE id = ?").bind(uid).first<{ claude_day: string; claude_count: number }>();
  const used = u?.claude_day === today ? u.claude_count : 0;
  if (used >= Number(c.env.CLAUDE_DAILY_LIMIT)) throw new HttpError(429, "daily_limit", "You've hit today's limit for Claude. It resets at midnight UTC.");
  await c.env.DB.prepare("UPDATE users SET claude_day = ?, claude_count = ? WHERE id = ?").bind(today, used + 1, uid).run();

  const res = await fetch(`${c.env.ANTHROPIC_BASE || "https://api.anthropic.com"}/v1/messages`, {
    method: "POST",
    headers: { "content-type": "application/json", "x-api-key": c.env.ANTHROPIC_API_KEY, "anthropic-version": "2023-06-01" },
    body: JSON.stringify({
      model: c.env.CLAUDE_MODEL,
      max_tokens: Math.min(Number(body.maxTokens) || 2000, Number(c.env.CLAUDE_MAX_TOKENS)),
      ...(body.system ? { system: body.system } : {}),
      ...(Number.isFinite(body.temperature) ? { temperature: body.temperature } : {}),
      messages: body.messages,
    }),
  });
  const data: any = await res.json().catch(() => ({}));
  if (!res.ok) {
    const msg = res.status === 429 || res.status === 529 ? "Claude is busy right now. Try again in a minute." : (data?.error?.message || "Claude couldn't answer. Try again.");
    throw new HttpError(res.status >= 500 ? 502 : res.status === 429 ? 429 : 502, "claude_error", msg);
  }
  const text = (data.content || []).filter((b: any) => b.type === "text").map((b: any) => b.text).join("");
  return c.json({ text, stopReason: data.stop_reason, usage: data.usage });
});

/* ---------- Instagram connection ---------- */

app.get("/v1/instagram/connect", async (c) => c.json({ url: await startConnect(c.env, c.get("uid")) }));

app.post("/v1/instagram/disconnect", async (c) => {
  await c.env.DB.prepare("DELETE FROM ig_accounts WHERE user_id = ?").bind(c.get("uid")).run();
  return c.json({ disconnected: true });
});

app.get("/instagram/callback", async (c) => {
  const back = (q: Record<string, string>) => c.redirect(`${c.env.APP_URL_SCHEME}://instagram?${new URLSearchParams(q)}`);
  const error = c.req.query("error");
  if (error) return back({ status: "cancelled" });
  try {
    const r = await finishConnect(c.env, c.req.query("code") || "", c.req.query("state") || "");
    return back({ status: "connected", username: r.username });
  } catch (e) {
    return back({ status: "error", message: e instanceof Error ? e.message : "Instagram connection failed." });
  }
});

/* ---------- Meta privacy callbacks ---------- */

// Meta sends a signed_request when someone removes the app or asks for their data to be deleted.
async function readSignedRequest(env: Env, c: any): Promise<{ user_id?: string } | null> {
  const form = await c.req.parseBody().catch(() => ({}));
  const sr = String((form as any).signed_request || "");
  const [sig, payload] = sr.split(".");
  if (!sig || !payload || !env.IG_APP_SECRET) return null;
  const expected = await hmac(env.IG_APP_SECRET, payload);
  if (expected !== sig.replace(/=+$/, "")) return null;
  try { return JSON.parse(new TextDecoder().decode(b64urlDecode(payload))); } catch { return null; }
}

app.post("/instagram/deauthorize", async (c) => {
  const data = await readSignedRequest(c.env, c);
  if (!data?.user_id) return c.json({ error: "invalid request" }, 400);
  await c.env.DB.prepare("DELETE FROM ig_accounts WHERE ig_user_id = ?").bind(String(data.user_id)).run();
  return c.json({ ok: true });
});

app.post("/instagram/data-deletion", async (c) => {
  const data = await readSignedRequest(c.env, c);
  if (!data?.user_id) return c.json({ error: "invalid request" }, 400);
  await c.env.DB.prepare("DELETE FROM ig_accounts WHERE ig_user_id = ?").bind(String(data.user_id)).run();
  const code = newId("del_");
  return c.json({ url: `${c.env.PUBLIC_URL}/instagram/deletion-status?code=${code}`, confirmation_code: code });
});

app.get("/instagram/deletion-status", (c) =>
  c.text(`Deletion request ${c.req.query("code") || ""}: your Instagram connection and its access token have been deleted from Clip Studio.`));

/* ---------- auto-posting ---------- */

app.post("/v1/items/:id/retry", async (c) => {
  const uid = c.get("uid");
  const cur = await getItem(c.env, uid, c.req.param("id"));
  if (!cur || cur.post_state !== "failed") throw new HttpError(400, "not_failed", "Only failed posts can be retried.");
  await c.env.DB.prepare("UPDATE items SET post_state='queued', post_error=NULL, post_attempts=0, ig_container_id=NULL, ig_children=NULL, publish_at=?, updated_at=? WHERE id=?")
    .bind(nowSec(), nowSec(), cur.id).run();
  return c.json({ item: toJson((await getItem(c.env, uid, cur.id))!) });
});

export default {
  fetch: app.fetch,
  async scheduled(_event: ScheduledEvent, env: Env, ctx: ExecutionContext) {
    ctx.waitUntil(runPublisher(env).then((r) => console.log("publisher", JSON.stringify(r))));
  },
};
