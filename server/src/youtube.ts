import { Env, HttpError, cleanupIfDone, newId, nowSec } from "./util";

// YouTube Shorts: Google sign-in, token refresh and uploads.
// A vertical video up to 3 minutes is a Short automatically; there's no separate Shorts upload.

export const YT_SCOPES = [
  "https://www.googleapis.com/auth/youtube.upload",
  "https://www.googleapis.com/auth/youtube.readonly", // only to show which channel is connected
];
const authUrl = (env: Env) => env.GOOGLE_AUTH_URL || "https://accounts.google.com/o/oauth2/v2/auth";
const oauthBase = (env: Env) => env.GOOGLE_OAUTH_BASE || "https://oauth2.googleapis.com";
const apiBase = (env: Env) => env.YT_API_BASE || "https://www.googleapis.com";
export const ytRedirectUri = (env: Env) => `${env.PUBLIC_URL}/youtube/callback`;

const MAX_RETRIES = 6;
const STUCK_AFTER = 30 * 60; // an upload that started this long ago and never finished was interrupted

export class YtError extends Error {
  constructor(message: string, public transient = false) {
    super(message);
  }
}

export interface YtAccount {
  user_id: string; channel_id: string | null; channel_title: string | null; channel_handle: string | null;
  refresh_token: string; access_token: string | null; access_expires_at: number;
}

async function gFetch(url: string, init?: RequestInit): Promise<{ body: any; res: Response }> {
  let res: Response;
  try {
    res = await fetch(url, init);
  } catch (e) {
    throw new YtError(`Couldn't reach YouTube: ${e}`, true);
  }
  const text = await res.text();
  let body: any;
  try { body = text ? JSON.parse(text) : {}; } catch { body = { raw: text }; }
  if (!res.ok) {
    const err = body?.error;
    const reason: string = err?.errors?.[0]?.reason || (typeof err === "string" ? err : "");
    if (reason === "invalid_grant") {
      throw new YtError("Your YouTube connection stopped working. Reconnect YouTube in Settings, then retry.");
    }
    if (reason === "quotaExceeded") throw new YtError("YouTube's daily upload allowance for Clip Studio is used up. It retries automatically.", true);
    if (reason === "uploadLimitExceeded") throw new YtError("Your channel has hit YouTube's daily upload limit. Try again tomorrow.");
    const msg = err?.message || body?.error_description || (typeof err === "string" ? err : "") || `YouTube returned ${res.status}`;
    throw new YtError(msg, res.status >= 500 || res.status === 429);
  }
  return { body, res };
}

/* ---------- connecting ---------- */

/** Where the app sends the user to connect their YouTube channel. */
export async function startYouTubeConnect(env: Env, userId: string): Promise<string> {
  if (!env.GOOGLE_CLIENT_ID || !env.GOOGLE_CLIENT_SECRET) {
    throw new HttpError(503, "not_configured", "YouTube isn't set up on the server yet (the Google client ID or secret is missing).");
  }
  const state = newId("y_");
  await env.DB.prepare("DELETE FROM oauth_states WHERE created_at < ?").bind(nowSec() - 3600).run();
  await env.DB.prepare("INSERT INTO oauth_states (state, user_id, created_at) VALUES (?, ?, ?)").bind(state, userId, nowSec()).run();
  const q = new URLSearchParams({
    client_id: env.GOOGLE_CLIENT_ID,
    redirect_uri: ytRedirectUri(env),
    response_type: "code",
    scope: YT_SCOPES.join(" "),
    access_type: "offline", // gives a refresh token, so posting works while you're away
    prompt: "consent",
    include_granted_scopes: "true",
    state,
  });
  return `${authUrl(env)}?${q}`;
}

/** Google sends the user back here: trade the code for tokens, find the channel and save it. */
export async function finishYouTubeConnect(env: Env, code: string, state: string): Promise<{ channel: string }> {
  const row = state.startsWith("y_")
    ? await env.DB.prepare("SELECT user_id, created_at FROM oauth_states WHERE state = ?").bind(state).first<{ user_id: string; created_at: number }>()
    : null;
  if (!row || row.created_at < nowSec() - 3600) throw new HttpError(400, "expired", "That YouTube login expired. Start again from the app.");
  await env.DB.prepare("DELETE FROM oauth_states WHERE state = ?").bind(state).run();

  const { body: tok } = await gFetch(`${oauthBase(env)}/token`, {
    method: "POST",
    body: new URLSearchParams({
      code, client_id: env.GOOGLE_CLIENT_ID!, client_secret: env.GOOGLE_CLIENT_SECRET!,
      redirect_uri: ytRedirectUri(env), grant_type: "authorization_code",
    }),
  });
  const granted = String(tok.scope || "");
  if (!granted.includes("youtube.upload")) {
    throw new HttpError(400, "no_upload_permission", "Clip Studio needs permission to upload videos. Connect again and tick the box to manage your YouTube videos.");
  }
  if (!tok.refresh_token) {
    throw new HttpError(400, "no_refresh_token", "Google didn't give Clip Studio a lasting login. Remove Clip Studio under Third-party access in your Google Account, then connect again.");
  }
  const access: string = tok.access_token;
  const { body: ch } = await gFetch(`${apiBase(env)}/youtube/v3/channels?${new URLSearchParams({ part: "snippet", mine: "true" })}`, {
    headers: { Authorization: `Bearer ${access}` },
  });
  const c = ch?.items?.[0];
  if (!c) throw new HttpError(400, "no_channel", "This Google account doesn't have a YouTube channel yet. Create one on YouTube, then connect again.");
  const now = nowSec();
  await env.DB.prepare(
    `INSERT INTO yt_accounts (user_id, channel_id, channel_title, channel_handle, refresh_token, access_token, access_expires_at, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT(user_id) DO UPDATE SET channel_id=excluded.channel_id, channel_title=excluded.channel_title,
       channel_handle=excluded.channel_handle, refresh_token=excluded.refresh_token, access_token=excluded.access_token,
       access_expires_at=excluded.access_expires_at, updated_at=excluded.updated_at`
  ).bind(row.user_id, c.id, c.snippet?.title || null, c.snippet?.customUrl || null, tok.refresh_token, access,
    now + Number(tok.expires_in || 3600), now).run();
  return { channel: c.snippet?.title || "" };
}

/** Disconnect: tell Google to revoke Clip Studio's access, then forget the tokens. */
export async function disconnectYouTube(env: Env, userId: string): Promise<void> {
  const acct = await env.DB.prepare("SELECT refresh_token FROM yt_accounts WHERE user_id = ?").bind(userId).first<{ refresh_token: string }>();
  if (acct) {
    try {
      await fetch(`${oauthBase(env)}/revoke`, { method: "POST", body: new URLSearchParams({ token: acct.refresh_token }) });
    } catch (e) {
      console.log("yt revoke", String(e));
    }
  }
  await env.DB.prepare("DELETE FROM yt_accounts WHERE user_id = ?").bind(userId).run();
}

/** A current access token, refreshed when it's about to expire (they last an hour). */
async function accessToken(env: Env, acct: YtAccount): Promise<string> {
  if (acct.access_token && acct.access_expires_at > nowSec() + 120) return acct.access_token;
  const { body } = await gFetch(`${oauthBase(env)}/token`, {
    method: "POST",
    body: new URLSearchParams({
      client_id: env.GOOGLE_CLIENT_ID || "", client_secret: env.GOOGLE_CLIENT_SECRET || "",
      refresh_token: acct.refresh_token, grant_type: "refresh_token",
    }),
  });
  const exp = nowSec() + Number(body.expires_in || 3600);
  await env.DB.prepare("UPDATE yt_accounts SET access_token = ?, access_expires_at = ?, updated_at = ? WHERE user_id = ?")
    .bind(body.access_token, exp, nowSec(), acct.user_id).run();
  return body.access_token;
}

/* ---------- uploading ---------- */

interface Row {
  id: string; user_id: string; title: string; yt_title: string | null; caption: string; media: string; yt_attempts: number;
}

// YouTube doesn't allow < or > in titles and descriptions.
const clean = (s: string, max: number) => s.replace(/[<>]/g, "").trim().slice(0, max);

/** Uploads one post's video. A resumable upload: one request with the details, then the file streamed from storage. */
async function upload(env: Env, acct: YtAccount, row: Row): Promise<{ id: string; privacy: string }> {
  const media: { key: string; type: string }[] = JSON.parse(row.media || "[]");
  const video = media.find((m) => m.type === "video");
  if (!video) throw new YtError("YouTube Shorts needs a video, and this post doesn't have one.");
  const obj = await env.MEDIA.get(video.key);
  if (!obj) throw new YtError("The video file isn't on the server anymore. Re-edit or re-upload the clip, then retry.");
  const contentType = obj.httpMetadata?.contentType || "video/mp4";
  const token = await accessToken(env, acct);
  const meta = {
    snippet: {
      title: clean(row.yt_title || row.title || "Untitled", 100) || "Untitled",
      description: clean(row.caption || "", 5000),
      categoryId: "10", // Music
    },
    status: { privacyStatus: "public", selfDeclaredMadeForKids: false },
  };
  const { res: start } = await gFetch(`${apiBase(env)}/upload/youtube/v3/videos?uploadType=resumable&part=snippet,status`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json; charset=UTF-8",
      "X-Upload-Content-Length": String(obj.size),
      "X-Upload-Content-Type": contentType,
    },
    body: JSON.stringify(meta),
  });
  const location = start.headers.get("Location");
  if (!location) throw new YtError("YouTube didn't start the upload. It retries automatically.", true);

  // Stream the file with a known length (no need to hold the whole video in memory).
  const { readable, writable } = new FixedLengthStream(obj.size);
  const piping = obj.body.pipeTo(writable);
  const { body } = await gFetch(location, { method: "PUT", headers: { "Content-Type": contentType }, body: readable });
  await piping.catch(() => {});
  if (!body?.id) throw new YtError("YouTube didn't confirm the upload. It retries automatically.", true);
  return { id: String(body.id), privacy: String(body.status?.privacyStatus || "") };
}

async function setFields(env: Env, id: string, fields: Record<string, unknown>) {
  const keys = Object.keys(fields);
  await env.DB.prepare(`UPDATE items SET ${keys.map((k) => `${k} = ?`).join(", ")}, updated_at = ? WHERE id = ?`)
    .bind(...keys.map((k) => fields[k] ?? null), nowSec(), id).run();
}

/** Uploads every YouTube post that's due. Runs with the Instagram publisher every 5 minutes. */
export async function runYouTube(env: Env): Promise<number> {
  const now = nowSec();
  // An upload that never finished (the server was stopped mid-way): let the person decide whether to retry.
  await env.DB.prepare(
    `UPDATE items SET yt_state = 'failed', yt_error = ?, updated_at = ? WHERE yt_state = 'uploading' AND yt_started_at < ?`
  ).bind("The YouTube upload was interrupted. Check your channel before retrying, in case it went through.", now, now - STUCK_AFTER).run();

  const { results } = await env.DB.prepare(
    `SELECT id, user_id, title, yt_title, caption, media, yt_attempts FROM items
     WHERE yt_state = 'queued' AND publish_at <= ? ORDER BY publish_at LIMIT 5`
  ).bind(now).all<Row>();
  let done = 0;
  for (const row of results) {
    // Claim it, so a second run at the same moment doesn't upload it twice.
    const claim = await env.DB.prepare(
      "UPDATE items SET yt_state = 'uploading', yt_started_at = ?, updated_at = ? WHERE id = ? AND yt_state = 'queued'"
    ).bind(now, now, row.id).run();
    if (!claim.meta.changes) continue;
    const acct = await env.DB.prepare("SELECT * FROM yt_accounts WHERE user_id = ?").bind(row.user_id).first<YtAccount>();
    if (!acct) {
      await setFields(env, row.id, { yt_state: "failed", yt_error: "Connect YouTube in Settings, then retry." });
      continue;
    }
    try {
      const v = await upload(env, acct, row);
      await setFields(env, row.id, { yt_state: "posted", yt_video_id: v.id, yt_privacy: v.privacy, yt_error: null, yt_attempts: 0 });
      await cleanupIfDone(env, row.id);
      done++;
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      if (e instanceof YtError && e.transient && row.yt_attempts + 1 < MAX_RETRIES) {
        await setFields(env, row.id, { yt_state: "queued", yt_attempts: row.yt_attempts + 1, yt_error: `Retrying: ${msg}` });
      } else {
        await setFields(env, row.id, { yt_state: "failed", yt_error: msg });
      }
    }
  }
  return done;
}
