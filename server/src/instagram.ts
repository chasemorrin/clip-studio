import { Env, HttpError, newId, nowSec } from "./util";

const graph = (env: Env) => `${env.IG_GRAPH_BASE || "https://graph.instagram.com"}`;
const oauthBase = (env: Env) => env.IG_OAUTH_BASE || "https://api.instagram.com";
export const redirectUri = (env: Env) => `${env.PUBLIC_URL}/instagram/callback`;

export class IgError extends Error {
  constructor(message: string, public transient = false) {
    super(message);
  }
}

async function igFetch(url: string, init?: RequestInit): Promise<any> {
  let res: Response;
  try {
    res = await fetch(url, init);
  } catch (e) {
    throw new IgError(`Couldn't reach Instagram: ${e}`, true);
  }
  const text = await res.text();
  let body: any;
  try { body = JSON.parse(text); } catch { body = { raw: text }; }
  if (!res.ok || body?.error) {
    const err = body?.error || {};
    const msg = err.error_user_msg || err.message || body?.error_message || `Instagram returned ${res.status}`;
    // Rate limits and server errors are worth retrying on the next run.
    throw new IgError(msg, res.status >= 500 || res.status === 429 || err.is_transient === true || err.code === 4 || err.code === 2);
  }
  return body;
}

/** Where the app sends the user to connect their Instagram account. */
export async function startConnect(env: Env, userId: string): Promise<string> {
  if (!env.IG_APP_ID) throw new HttpError(503, "not_configured", "Instagram isn't set up on the server yet.");
  const state = newId("s_");
  await env.DB.prepare("DELETE FROM oauth_states WHERE created_at < ?").bind(nowSec() - 3600).run();
  await env.DB.prepare("INSERT INTO oauth_states (state, user_id, created_at) VALUES (?, ?, ?)").bind(state, userId, nowSec()).run();
  const q = new URLSearchParams({
    client_id: env.IG_APP_ID,
    redirect_uri: redirectUri(env),
    response_type: "code",
    scope: "instagram_business_basic,instagram_business_content_publish",
    state,
  });
  return `https://www.instagram.com/oauth/authorize?${q}`;
}

/** Instagram sends the user back here; trade the code for a 60-day token and save it. */
export async function finishConnect(env: Env, code: string, state: string): Promise<{ username: string }> {
  const row = await env.DB.prepare("SELECT user_id, created_at FROM oauth_states WHERE state = ?").bind(state).first<{ user_id: string; created_at: number }>();
  if (!row || row.created_at < nowSec() - 3600) throw new HttpError(400, "expired", "That Instagram login expired. Start again from the app.");
  await env.DB.prepare("DELETE FROM oauth_states WHERE state = ?").bind(state).run();

  const form = new URLSearchParams({
    client_id: env.IG_APP_ID,
    client_secret: env.IG_APP_SECRET,
    grant_type: "authorization_code",
    redirect_uri: redirectUri(env),
    code: code.replace(/#_$/, ""),
  });
  const short = await igFetch(`${oauthBase(env)}/oauth/access_token`, { method: "POST", body: form });
  const s = Array.isArray(short?.data) ? short.data[0] : short;
  if (!s?.access_token) throw new HttpError(502, "ig_failed", "Instagram didn't return a login. Try again.");

  const long = await igFetch(`${graph(env)}/access_token?${new URLSearchParams({ grant_type: "ig_exchange_token", client_secret: env.IG_APP_SECRET, access_token: s.access_token })}`);
  const token: string = long.access_token;
  const me = await igFetch(`${graph(env)}/${env.IG_API_VERSION}/me?${new URLSearchParams({ fields: "user_id,username", access_token: token })}`);
  const igUserId = String(me.user_id || me.id || s.user_id);
  const now = nowSec();
  await env.DB.prepare(
    `INSERT INTO ig_accounts (user_id, ig_user_id, username, access_token, token_issued_at, expires_at, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT(user_id) DO UPDATE SET ig_user_id=excluded.ig_user_id, username=excluded.username, access_token=excluded.access_token,
       token_issued_at=excluded.token_issued_at, expires_at=excluded.expires_at, updated_at=excluded.updated_at`
  ).bind(row.user_id, igUserId, me.username || null, token, now, now + Number(long.expires_in || 60 * 86400), now).run();
  return { username: me.username || "" };
}

export interface IgAccount { user_id: string; ig_user_id: string; username: string | null; access_token: string; token_issued_at: number; expires_at: number; }

/** Keeps tokens alive: refresh any that are a day old and expire within 20 days. */
export async function refreshTokens(env: Env): Promise<number> {
  const now = nowSec();
  const { results } = await env.DB.prepare(
    "SELECT * FROM ig_accounts WHERE expires_at > ? AND expires_at < ? AND token_issued_at < ? LIMIT 50"
  ).bind(now, now + 20 * 86400, now - 86400).all<IgAccount>();
  let n = 0;
  for (const a of results) {
    try {
      const r = await igFetch(`${graph(env)}/refresh_access_token?${new URLSearchParams({ grant_type: "ig_refresh_token", access_token: a.access_token })}`);
      await env.DB.prepare("UPDATE ig_accounts SET access_token=?, token_issued_at=?, expires_at=?, updated_at=? WHERE user_id=?")
        .bind(r.access_token, now, now + Number(r.expires_in || 60 * 86400), now, a.user_id).run();
      n++;
    } catch (e) {
      console.log("token refresh failed", a.user_id, String(e));
    }
  }
  return n;
}

const post = (env: Env, path: string, params: Record<string, string>) =>
  igFetch(`${graph(env)}/${env.IG_API_VERSION}/${path}?${new URLSearchParams(params)}`, { method: "POST" });

export function createContainer(env: Env, acct: IgAccount, params: Record<string, string>): Promise<{ id: string }> {
  return post(env, `${acct.ig_user_id}/media`, { ...params, access_token: acct.access_token });
}

export async function containerStatus(env: Env, acct: IgAccount, id: string): Promise<{ status_code: string; status?: string }> {
  return igFetch(`${graph(env)}/${env.IG_API_VERSION}/${id}?${new URLSearchParams({ fields: "status_code,status", access_token: acct.access_token })}`);
}

export async function publishContainer(env: Env, acct: IgAccount, creationId: string): Promise<{ id: string; permalink?: string }> {
  const r = await post(env, `${acct.ig_user_id}/media_publish`, { creation_id: creationId, access_token: acct.access_token });
  let permalink: string | undefined;
  try {
    const m = await igFetch(`${graph(env)}/${env.IG_API_VERSION}/${r.id}?${new URLSearchParams({ fields: "permalink", access_token: acct.access_token })}`);
    permalink = m.permalink;
  } catch { /* a missing link isn't worth failing the post over */ }
  return { id: r.id, permalink };
}
