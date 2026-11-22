import { Hono } from "hono";
import { Env, HttpError, b64urlDecode, hmac, hmacVerify, newId, nowSec, signedMediaUrl } from "./util";
import { createSession, readSession, userForAppleSub, verifyAppleToken } from "./auth";
import { connectWithToken, finishConnect, startConnect } from "./instagram";
import { runPublisher } from "./publisher";
import { disconnectYouTube, finishYouTubeConnect, startYouTubeConnect } from "./youtube";

type Vars = { uid: string };
const app = new Hono<{ Bindings: Env; Variables: Vars }>();

app.onError((err, c) => {
  if (err instanceof HttpError) return c.json({ error: { code: err.code, message: err.message } }, err.status as any);
  console.log("unhandled", err);
  return c.json({ error: { code: "server_error", message: "Something went wrong on the server. Try again." } }, 500);
});

const contact = (env: Env) => env.CONTACT_EMAIL
  ? `<a href="mailto:${env.CONTACT_EMAIL}">${env.CONTACT_EMAIL}</a>`
  : "the contact details on the Clip Studio listing";

const page = (title: string, body: string) => `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>${title} · Clip Studio</title>
<style>body{font:16px/1.6 -apple-system,system-ui,sans-serif;max-width:680px;margin:40px auto;padding:0 20px;color:#1c1c1e}
h1{font-size:28px}h2{font-size:18px;margin-top:28px}a{color:#b5562c}footer{margin-top:48px;font-size:14px;color:#777}
@media(prefers-color-scheme:dark){body{background:#111;color:#eee}a{color:#f0a070}}</style>
</head><body>${body}<footer><a href="/">Clip Studio</a> · <a href="/privacy">Privacy policy</a> · <a href="/terms">Terms of service</a></footer></body></html>`;

// Browsers get the homepage; the app and health checks get JSON.
app.get("/", (c) => {
  if (!(c.req.header("Accept") || "").includes("text/html")) return c.json({ ok: true, name: "clip-studio" });
  return c.html(page("Home", `
<h1>Clip Studio</h1>
<p>An iPhone app for musicians. Pick footage from your concerts or practice, find the best moments, trim them into vertical clips and schedule them on a posting calendar.</p>
<h2>Posts to Instagram and YouTube</h2>
<p>Connect your own Instagram account and YouTube channel, and Clip Studio publishes each clip at the time you choose: as a Reel on Instagram and as a Short on YouTube. You write and approve every title and caption, and you can change or cancel any post before it goes live.</p>
<p>Clip Studio uses YouTube API Services to upload your videos to your own channel. By using it you agree to the <a href="https://www.youtube.com/t/terms">YouTube Terms of Service</a>.</p>
<h2>Your data</h2>
<p>Read how Clip Studio handles your information in the <a href="/privacy">privacy policy</a>, and the rules for using it in the <a href="/terms">terms of service</a>.</p>
<p>Contact: ${contact(c.env)}</p>`));
});

app.get("/privacy", (c) => c.html(page("Privacy policy", `
<h1>Clip Studio privacy policy</h1>
<p>Last updated November 21, 2026.</p>
<p>Clip Studio helps musicians find short clips in their own performance videos, plan posts and publish them to their own Instagram account and YouTube channel.</p>
<h2>What we store</h2>
<ul>
<li>Your account: an anonymous ID from Sign in with Apple.</li>
<li>Your posting calendar: titles, captions, dates and notes you enter.</li>
<li>Clips you choose to schedule, only until they're posted. They're deleted from our storage after posting.</li>
<li>Your Instagram connection: the account ID, username and access token Meta provides, used only to publish the posts you schedule.</li>
<li>Your YouTube connection: your channel's ID, name and handle, and the access tokens Google provides, used only to upload the videos you schedule to your channel.</li>
</ul>
<h2>YouTube</h2>
<p>Clip Studio uses YouTube API Services. When you connect YouTube, you're also bound by the <a href="https://www.youtube.com/t/terms">YouTube Terms of Service</a>, and Google handles your information under the <a href="https://policies.google.com/privacy">Google Privacy Policy</a>.</p>
<ul>
<li>What Clip Studio accesses: permission to upload videos to your channel, and your channel's ID, name and handle so the app can show which channel is connected.</li>
<li>How it's used: only to upload the videos you schedule, with the title and description you approved, at the time you chose. Clip Studio doesn't read, download or analyze your other videos, comments, subscribers or analytics.</li>
<li>Sharing: this information isn't shared with anyone except Google, which receives your videos when they're uploaded.</li>
<li>Storage and deletion: your YouTube tokens and channel details are kept only while YouTube is connected. Disconnecting YouTube in the app's Settings revokes Clip Studio's access with Google and deletes them from our servers.</li>
<li>You can also revoke Clip Studio's access at any time on your Google Account's <a href="https://security.google.com/settings/security/permissions">security settings page</a>.</li>
</ul>
<h2>What we don't do</h2>
<ul>
<li>Your full videos stay on your phone. The app analyzes them on the device.</li>
<li>We don't sell or share your data, run ads, or use it to track you. The app and this website don't use cookies or other tracking technology.</li>
<li>We don't read your Instagram messages, comments or followers.</li>
</ul>
<h2>Claude</h2>
<p>When you ask Claude (by Anthropic) to suggest clips or write captions, a few still frames, an audio summary and your description of your music are sent to Anthropic's API to produce the answer.</p>
<h2>Deleting your data</h2>
<p>In the app, open Settings and choose Delete account and data. This removes everything above from our servers and revokes Clip Studio's YouTube access. Removing Clip Studio from your Meta or Instagram settings also deletes the Instagram connection.</p>
<h2>Contact</h2>
<p>Questions: ${contact(c.env)}.</p>`)));

app.get("/terms", (c) => c.html(page("Terms", `
<h1>Clip Studio terms of service</h1>
<p>Last updated November 21, 2026.</p>
<p>Use Clip Studio only with videos and music you have the right to post. You're responsible for what you publish to your Instagram account and YouTube channel.</p>
<p>Clip Studio uses YouTube API Services. By using Clip Studio, you agree to be bound by the <a href="https://www.youtube.com/t/terms">YouTube Terms of Service</a>.</p>
<p>The service is provided as is, without warranty.</p>
<p>Contact: ${contact(c.env)}.</p>`)));

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
  const yt = await c.env.DB.prepare("SELECT channel_id, channel_title, channel_handle FROM yt_accounts WHERE user_id = ?").bind(uid)
    .first<{ channel_id: string; channel_title: string; channel_handle: string | null }>();
  const u = await c.env.DB.prepare("SELECT claude_day, claude_count FROM users WHERE id = ?").bind(uid).first<{ claude_day: string; claude_count: number }>();
  const today = new Date().toISOString().slice(0, 10);
  return c.json({
    userId: uid,
    instagram: ig ? { username: ig.username, expiresAt: ig.expires_at, expired: ig.expires_at < nowSec() } : null,
    youtube: yt ? { channelId: yt.channel_id, channelTitle: yt.channel_title, handle: yt.channel_handle } : null,
    youtubeAvailable: !!(c.env.GOOGLE_CLIENT_ID && c.env.GOOGLE_CLIENT_SECRET),
    claude: { usedToday: u?.claude_day === today ? u.claude_count : 0, dailyLimit: Number(c.env.CLAUDE_DAILY_LIMIT) },
  });
});

// Required by the App Store: delete the account and everything stored with it.
app.delete("/v1/me", async (c) => {
  const uid = c.get("uid");
  const { results } = await c.env.DB.prepare("SELECT key FROM media WHERE user_id = ?").bind(uid).all<{ key: string }>();
  for (const r of results) await c.env.MEDIA.delete(r.key);
  await disconnectYouTube(c.env, uid);
  for (const t of ["media", "items", "ig_accounts", "yt_accounts", "oauth_states"]) {
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
  yt_state: string | null; yt_title: string | null; yt_video_id: string | null; yt_privacy: string | null; yt_error: string | null;
}

const toJson = (r: ItemRow) => ({
  id: r.id, title: r.title, pillar: r.pillar, format: r.format, date: r.date, status: r.status, notes: r.notes,
  plan: r.plan ? JSON.parse(r.plan) : null, caption: r.caption, media: JSON.parse(r.media || "[]"), coverMs: r.cover_ms,
  publishAt: r.publish_at, postState: r.post_state, instagramMediaId: r.ig_media_id, permalink: r.ig_permalink,
  postError: r.post_error, createdAt: r.created_at, updatedAt: r.updated_at,
  youtube: {
    state: r.yt_state, title: r.yt_title, videoId: r.yt_video_id, privacy: r.yt_privacy, error: r.yt_error,
    url: r.yt_video_id ? `https://youtube.com/shorts/${r.yt_video_id}` : null,
  },
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
  if ("ytTitle" in body) f.yt_title = typeof body.ytTitle === "string" ? body.ytTitle.slice(0, 100) : null;

  // YouTube: the app sends youtube true/false.
  if ("youtube" in body) {
    if (current?.yt_state === "uploading") throw new HttpError(409, "publishing", "This video is uploading to YouTube right now. Wait a few minutes.");
    if (body.youtube) {
      if (current?.yt_state !== "posted") {
        const publishAt = (f.publish_at as number | null | undefined) ?? current?.publish_at;
        const media: { type: string }[] = JSON.parse((f.media as string) ?? current?.media ?? "[]");
        if (!publishAt) throw new HttpError(400, "no_time", "Pick a date and time to post.");
        if (!media.some((m) => m.type === "video")) throw new HttpError(400, "no_video", "YouTube Shorts needs a video. Photos can only go to Instagram.");
        if (current?.yt_state !== "queued") { f.yt_state = "queued"; f.yt_error = null; f.yt_attempts = 0; }
      }
    } else if (current?.yt_state !== "posted") {
      f.yt_state = null; f.yt_error = null;
    }
  } else if (current?.yt_state === "uploading" && ("media" in f || "publish_at" in f)) {
    throw new HttpError(409, "publishing", "This video is uploading to YouTube right now. Wait a few minutes.");
  }

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
  if (current.post_state === "children" || current.post_state === "publishing" || current.yt_state === "uploading") {
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

// For your own account: paste an access token from Meta's dashboard instead of logging in.
app.post("/v1/instagram/token", async (c) => {
  const { token } = await c.req.json<{ token: string }>();
  const r = await connectWithToken(c.env, c.get("uid"), token);
  return c.json({ connected: true, username: r.username });
});

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

// Publish now instead of waiting for the 5-minute timer. Instagram still needs a little time
// to process a video; the timer finishes anything that isn't done within this request.
app.post("/v1/items/:id/publish-now", async (c) => {
  const uid = c.get("uid");
  const body = await c.req.json<{ instagram?: boolean; youtube?: boolean }>().catch(() => ({} as { instagram?: boolean; youtube?: boolean }));
  const cur = await getItem(c.env, uid, c.req.param("id"));
  if (!cur) throw new HttpError(404, "not_found", "That post doesn't exist anymore.");
  const media: { type: string }[] = JSON.parse(cur.media || "[]");
  if (!media.length) throw new HttpError(400, "no_media", "There's no clip attached to this post.");
  const igBusy = cur.post_state === "children" || cur.post_state === "publishing";
  // By default: Instagram (as before), plus YouTube if it's switched on for this post.
  let wantIg = (body.instagram ?? true) && cur.post_state !== "posted" && !igBusy;
  let wantYt = (body.youtube ?? (cur.yt_state === "queued" || cur.yt_state === "failed")) && cur.yt_state !== "posted" && cur.yt_state !== "uploading";
  if (wantIg) {
    const ig = await c.env.DB.prepare("SELECT 1 FROM ig_accounts WHERE user_id = ?").bind(uid).first();
    if (!ig) {
      if (body.instagram || !wantYt) throw new HttpError(400, "no_instagram", "Connect Instagram in Settings first.");
      wantIg = false;
    }
  }
  if (wantYt) {
    const yt = await c.env.DB.prepare("SELECT 1 FROM yt_accounts WHERE user_id = ?").bind(uid).first();
    if (!yt) throw new HttpError(400, "no_youtube", "Connect YouTube in Settings first.");
    if (!media.some((m) => m.type === "video")) throw new HttpError(400, "no_video", "YouTube Shorts needs a video. Photos can only go to Instagram.");
  }
  if (!wantIg && !wantYt) {
    if (igBusy || cur.yt_state === "uploading") return c.json({ item: toJson(cur) });
    throw new HttpError(409, "posted", "This post is already up.");
  }
  const now = nowSec();
  await c.env.DB.prepare("UPDATE items SET publish_at=?, date=?, updated_at=? WHERE id=?")
    .bind(now, new Date(now * 1000).toISOString().slice(0, 10), now, cur.id).run();
  if (wantIg) {
    await c.env.DB.prepare("UPDATE items SET post_state='queued', post_error=NULL, post_attempts=0, ig_container_id=NULL, ig_children=NULL WHERE id=?")
      .bind(cur.id).run();
  }
  if (wantYt) {
    await c.env.DB.prepare("UPDATE items SET yt_state='queued', yt_error=NULL, yt_attempts=0 WHERE id=?").bind(cur.id).run();
  }
  // Instagram still needs a little time to process a video; the timer finishes anything not done within this request.
  c.executionCtx.waitUntil((async () => {
    await runPublisher(c.env);
    await new Promise((r) => setTimeout(r, 20_000));
    await runPublisher(c.env);
  })().catch((e) => console.log("publish-now", String(e))));
  return c.json({ item: toJson((await getItem(c.env, uid, cur.id))!) });
});

// Retries whatever failed: Instagram, YouTube or both.
app.post("/v1/items/:id/retry", async (c) => {
  const uid = c.get("uid");
  const cur = await getItem(c.env, uid, c.req.param("id"));
  const igFailed = cur?.post_state === "failed", ytFailed = cur?.yt_state === "failed";
  if (!cur || (!igFailed && !ytFailed)) throw new HttpError(400, "not_failed", "Only failed posts can be retried.");
  const now = nowSec();
  if (igFailed) {
    await c.env.DB.prepare("UPDATE items SET post_state='queued', post_error=NULL, post_attempts=0, ig_container_id=NULL, ig_children=NULL WHERE id=?")
      .bind(cur.id).run();
  }
  if (ytFailed) await c.env.DB.prepare("UPDATE items SET yt_state='queued', yt_error=NULL, yt_attempts=0 WHERE id=?").bind(cur.id).run();
  await c.env.DB.prepare("UPDATE items SET publish_at=?, updated_at=? WHERE id=?").bind(now, now, cur.id).run();
  return c.json({ item: toJson((await getItem(c.env, uid, cur.id))!) });
});

/* ---------- YouTube connection ---------- */

app.get("/v1/youtube/connect", async (c) => c.json({ url: await startYouTubeConnect(c.env, c.get("uid")) }));

app.post("/v1/youtube/disconnect", async (c) => {
  await disconnectYouTube(c.env, c.get("uid"));
  return c.json({ disconnected: true });
});

app.get("/youtube/callback", async (c) => {
  const back = (q: Record<string, string>) => c.redirect(`${c.env.APP_URL_SCHEME}://youtube?${new URLSearchParams(q)}`);
  if (c.req.query("error")) return back({ status: "cancelled" });
  try {
    const r = await finishYouTubeConnect(c.env, c.req.query("code") || "", c.req.query("state") || "");
    return back({ status: "connected", channel: r.channel });
  } catch (e) {
    return back({ status: "error", message: e instanceof Error ? e.message : "YouTube connection failed." });
  }
});

export default {
  fetch: app.fetch,
  async scheduled(_event: ScheduledEvent, env: Env, ctx: ExecutionContext) {
    ctx.waitUntil(runPublisher(env).then((r) => console.log("publisher", JSON.stringify(r))));
  },
};
