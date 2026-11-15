import { Env, HttpError, b64url, b64urlDecode, hmac, hmacVerify, newId, nowSec } from "./util";

const SESSION_DAYS = 180;

/** Creates the app's login token: v1.<payload>.<signature>. */
export async function createSession(env: Env, userId: string): Promise<string> {
  const payload = b64url(JSON.stringify({ uid: userId, exp: nowSec() + SESSION_DAYS * 86400 }));
  return `v1.${payload}.${await hmac(env.SESSION_SECRET, payload)}`;
}

export async function readSession(env: Env, header: string | null | undefined): Promise<string> {
  const token = header?.startsWith("Bearer ") ? header.slice(7) : "";
  const [v, payload, sig] = token.split(".");
  if (v !== "v1" || !payload || !sig || !(await hmacVerify(env.SESSION_SECRET, payload, sig))) {
    throw new HttpError(401, "signed_out", "Sign in again.");
  }
  const data = JSON.parse(new TextDecoder().decode(b64urlDecode(payload)));
  if (!data.uid || data.exp < nowSec()) throw new HttpError(401, "signed_out", "Your sign-in expired. Sign in again.");
  return data.uid as string;
}

let appleKeys: { keys: JsonWebKey[]; at: number } | null = null;

async function getAppleKey(env: Env, kid: string): Promise<JsonWebKey | undefined> {
  if (!appleKeys || Date.now() - appleKeys.at > 6 * 3600 * 1000 || !appleKeys.keys.some((k: any) => k.kid === kid)) {
    const res = await fetch(env.APPLE_KEYS_URL || "https://appleid.apple.com/auth/keys");
    if (!res.ok) throw new HttpError(502, "apple_unavailable", "Couldn't reach Apple to check your sign-in. Try again.");
    appleKeys = { keys: ((await res.json()) as any).keys, at: Date.now() };
  }
  return appleKeys.keys.find((k: any) => k.kid === kid);
}

/** Checks a Sign in with Apple identity token and returns Apple's user id ("sub"). */
export async function verifyAppleToken(env: Env, idToken: string): Promise<string> {
  const parts = idToken.split(".");
  if (parts.length !== 3) throw new HttpError(400, "bad_token", "That sign-in didn't work. Try again.");
  const header = JSON.parse(new TextDecoder().decode(b64urlDecode(parts[0])));
  const claims = JSON.parse(new TextDecoder().decode(b64urlDecode(parts[1])));
  const jwk = await getAppleKey(env, header.kid);
  if (!jwk || header.alg !== "RS256") throw new HttpError(401, "bad_token", "That sign-in didn't work. Try again.");
  const key = await crypto.subtle.importKey("jwk", jwk, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["verify"]);
  const ok = await crypto.subtle.verify("RSASSA-PKCS1-v1_5", key, b64urlDecode(parts[2]), new TextEncoder().encode(`${parts[0]}.${parts[1]}`));
  if (!ok) throw new HttpError(401, "bad_token", "That sign-in didn't work. Try again.");
  if (claims.iss !== "https://appleid.apple.com") throw new HttpError(401, "bad_token", "That sign-in didn't come from Apple.");
  if (claims.aud !== env.APPLE_BUNDLE_ID) throw new HttpError(401, "bad_token", "That sign-in was for a different app.");
  if (claims.exp < nowSec()) throw new HttpError(401, "bad_token", "That sign-in expired. Try again.");
  return claims.sub as string;
}

export async function userForAppleSub(env: Env, sub: string): Promise<string> {
  const row = await env.DB.prepare("SELECT id FROM users WHERE apple_sub = ?").bind(sub).first<{ id: string }>();
  if (row) return row.id;
  const id = newId("u_");
  await env.DB.prepare("INSERT INTO users (id, apple_sub, created_at) VALUES (?, ?, ?)").bind(id, sub, nowSec()).run();
  return id;
}
