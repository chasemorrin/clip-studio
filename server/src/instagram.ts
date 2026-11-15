import { Env, HttpError, newId, nowSec } from "./util";

const graph = (env: Env) => `${env.IG_GRAPH_BASE || "https://graph.instagram.com"}`;
const fbGraph = (env: Env) => `${env.FB_GRAPH_BASE || "https://graph.facebook.com"}`;
const unified = (env: Env) => !!env.IG_LOGIN_URL;
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
  if (!env.IG_APP_ID && !unified(env)) throw new HttpError(503, "not_configured", "Instagram isn't set up on the server yet.");
  if (!env.IG_APP_SECRET) throw new HttpError(503, "not_configured", "Instagram isn't set up on the server yet (the app secret is missing).");
  const state = newId("s_");
  await env.DB.prepare("DELETE FROM oauth_states WHERE created_at < ?").bind(nowSec() - 3600).run();
  await env.DB.prepare("INSERT INTO oauth_states (state, user_id, created_at) VALUES (?, ?, ?)").bind(state, userId, nowSec()).run();
  if (unified(env)) {
    // Use Meta's own login URL for the configuration, adding our state value.
    const u = new URL(env.IG_LOGIN_URL!);
    u.searchParams.set("state", state);
    return u.toString();
  }
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
  if (unified(env)) return finishUnified(env, row.user_id, code);

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

/** Unified login: trade the code for a system-user token and find the Instagram account it was given. */
async function finishUnified(env: Env, userId: string, code: string): Promise<{ username: string }> {
  const tpl = new URL(env.IG_LOGIN_URL!);
  const clientId = tpl.searchParams.get("client_id") || env.IG_APP_ID;
  const redirect = tpl.searchParams.get("redirect_uri") || redirectUri(env);
  const v = env.IG_API_VERSION;
  const tok = await igFetch(`${fbGraph(env)}/${v}/oauth/access_token?${new URLSearchParams({
    client_id: clientId, client_secret: env.IG_APP_SECRET, redirect_uri: redirect, code: code.replace(/#_$/, ""),
  })}`);
  const token: string = tok.access_token;
  if (!token) throw new HttpError(502, "ig_failed", "Meta didn't return a login. Try again.");

  // Which Instagram account did the person share? Meta reports it in different places depending on
  // how the app and the account are owned, so try each one and keep a short note of what we found.
  const notes: string[] = [];
  const found: { id: string; username?: string }[] = [];
  const add = (list: any[]) => { for (const a of list || []) if (a?.id && !found.some((f) => f.id === String(a.id))) found.push({ id: String(a.id), username: a.username }); };
  const tryEdge = async (label: string, url: string, pick: (r: any) => any[]) => {
    if (found.length) return;
    try {
      const r = await igFetch(url);
      const list = pick(r) || [];
      notes.push(`${label} ${list.length}`);
      add(list);
    } catch (e) {
      notes.push(`${label} error`);
      console.log("ig discovery", label, String(e));
    }
  };
  const q = (params: Record<string, string>) => new URLSearchParams({ ...params, access_token: token });

  await tryEdge("assigned", `${fbGraph(env)}/${v}/me/assigned_instagram_accounts?${q({ fields: "id,username" })}`, (r) => r?.data);
  await tryEdge("scopes", `${fbGraph(env)}/${v}/debug_token?${new URLSearchParams({ input_token: token, access_token: `${clientId}|${env.IG_APP_SECRET}` })}`, (r) => {
    const scopes: any[] = r?.data?.granular_scopes || [];
    const ids = scopes.filter((s) => String(s.scope).startsWith("instagram")).flatMap((s) => s.target_ids || []);
    return [...new Set(ids)].map((id) => ({ id }));
  });
  if (!found.length) {
    let biz = "";
    try {
      const me = await igFetch(`${fbGraph(env)}/${v}/me?${q({ fields: "id,client_business_id" })}`);
      biz = me?.client_business_id ? String(me.client_business_id) : "";
      notes.push(biz ? "business found" : "no business");
    } catch (e) {
      notes.push("business error");
      console.log("ig discovery me", String(e));
    }
    if (biz) {
      for (const edge of ["instagram_business_accounts", "owned_instagram_accounts", "instagram_accounts"]) {
        await tryEdge(edge.replace(/_/g, " "), `${fbGraph(env)}/${v}/${biz}/${edge}?${q({ fields: "id,username" })}`, (r) => r?.data);
      }
    }
  }
  await tryEdge("pages", `${fbGraph(env)}/${v}/me/accounts?${q({ fields: "instagram_business_account{id,username}" })}`,
    (r) => (r?.data || []).map((p: any) => p.instagram_business_account).filter(Boolean));
  if (!found.length && env.IG_ACCOUNT_ID) {
    // Last resort: the Instagram account ID shown in Meta's dashboard, set on the server.
    await tryEdge("configured", `${fbGraph(env)}/${v}/${env.IG_ACCOUNT_ID}?${q({ fields: "id,username" })}`, (r) => (r?.id ? [r] : []));
  }
  console.log("ig discovery", notes.join(", "));
  if (!found.length) {
    throw new HttpError(400, "no_account",
      `Meta didn't say which Instagram account you shared. Checked: ${notes.join(", ")}. Send this message to Claude.`);
  }
  const igUserId = found[0].id;

  let username = found[0].username || "";
  if (!username) try {
    const me = await igFetch(`${fbGraph(env)}/${v}/${igUserId}?${new URLSearchParams({ fields: "username", access_token: token })}`);
    username = me.username || "";
  } catch { /* the name is nice to have, not required */ }

  const now = nowSec();
  const expiresAt = tok.expires_in ? now + Number(tok.expires_in) : now + 10 * 365 * 86400; // system-user tokens don't expire
  await env.DB.prepare(
    `INSERT INTO ig_accounts (user_id, ig_user_id, username, access_token, token_issued_at, expires_at, updated_at, kind)
     VALUES (?, ?, ?, ?, ?, ?, ?, 'facebook')
     ON CONFLICT(user_id) DO UPDATE SET ig_user_id=excluded.ig_user_id, username=excluded.username, access_token=excluded.access_token,
       token_issued_at=excluded.token_issued_at, expires_at=excluded.expires_at, updated_at=excluded.updated_at, kind='facebook'`
  ).bind(userId, igUserId, username || null, token, now, expiresAt, now).run();
  return { username };
}

export interface IgAccount { user_id: string; ig_user_id: string; username: string | null; access_token: string; token_issued_at: number; expires_at: number; kind?: string; }

/** Graph host for an account: Unified login accounts publish through graph.facebook.com. */
const hostFor = (env: Env, acct: IgAccount) => (acct.kind === "facebook" ? fbGraph(env) : graph(env));

/** Keeps tokens alive: refresh any that are a day old and expire within 20 days. */
export async function refreshTokens(env: Env): Promise<number> {
  const now = nowSec();
  const { results } = await env.DB.prepare(
    "SELECT * FROM ig_accounts WHERE kind = 'instagram' AND expires_at > ? AND expires_at < ? AND token_issued_at < ? LIMIT 50"
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

const post = (env: Env, acct: IgAccount, path: string, params: Record<string, string>) =>
  igFetch(`${hostFor(env, acct)}/${env.IG_API_VERSION}/${path}?${new URLSearchParams(params)}`, { method: "POST" });

export function createContainer(env: Env, acct: IgAccount, params: Record<string, string>): Promise<{ id: string }> {
  return post(env, acct, `${acct.ig_user_id}/media`, { ...params, access_token: acct.access_token });
}

export async function containerStatus(env: Env, acct: IgAccount, id: string): Promise<{ status_code: string; status?: string }> {
  return igFetch(`${hostFor(env, acct)}/${env.IG_API_VERSION}/${id}?${new URLSearchParams({ fields: "status_code,status", access_token: acct.access_token })}`);
}

export async function publishContainer(env: Env, acct: IgAccount, creationId: string): Promise<{ id: string; permalink?: string }> {
  const r = await post(env, acct, `${acct.ig_user_id}/media_publish`, { creation_id: creationId, access_token: acct.access_token });
  let permalink: string | undefined;
  try {
    const m = await igFetch(`${hostFor(env, acct)}/${env.IG_API_VERSION}/${r.id}?${new URLSearchParams({ fields: "permalink", access_token: acct.access_token })}`);
    permalink = m.permalink;
  } catch { /* a missing link isn't worth failing the post over */ }
  return { id: r.id, permalink };
}
