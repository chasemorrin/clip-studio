export interface Env {
  DB: D1Database;
  MEDIA: R2Bucket;
  PUBLIC_URL: string;
  APPLE_BUNDLE_ID: string;
  APP_URL_SCHEME: string;
  IG_APP_ID: string;
  IG_API_VERSION: string;
  CLAUDE_MODEL: string;
  CLAUDE_MAX_TOKENS: string;
  CLAUDE_DAILY_LIMIT: string;
  SESSION_SECRET: string;
  ANTHROPIC_API_KEY: string;
  IG_APP_SECRET: string;
  DEV_LOGIN_KEY?: string;
  // Test-only overrides so local tests can point at fake services.
  ANTHROPIC_BASE?: string;
  IG_GRAPH_BASE?: string;
  IG_OAUTH_BASE?: string;
  APPLE_KEYS_URL?: string;
}

export const nowSec = () => Math.floor(Date.now() / 1000);

export function newId(prefix = ""): string {
  const b = new Uint8Array(12);
  crypto.getRandomValues(b);
  return prefix + [...b].map((x) => x.toString(16).padStart(2, "0")).join("");
}

export function b64url(data: ArrayBuffer | Uint8Array | string): string {
  const bytes = typeof data === "string" ? new TextEncoder().encode(data) : new Uint8Array(data);
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function b64urlDecode(s: string): Uint8Array {
  s = s.replace(/-/g, "+").replace(/_/g, "/");
  while (s.length % 4) s += "=";
  const bin = atob(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

async function hmacKey(secret: string) {
  return crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign", "verify"]);
}

export async function hmac(secret: string, msg: string): Promise<string> {
  const sig = await crypto.subtle.sign("HMAC", await hmacKey(secret), new TextEncoder().encode(msg));
  return b64url(sig);
}

export async function hmacVerify(secret: string, msg: string, sig: string): Promise<boolean> {
  try {
    return await crypto.subtle.verify("HMAC", await hmacKey(secret), b64urlDecode(sig), new TextEncoder().encode(msg));
  } catch {
    return false;
  }
}

/** A short, signed link Instagram can use to download one file. */
export async function signedMediaUrl(env: Env, key: string, ttlSec = 6 * 3600): Promise<string> {
  const exp = nowSec() + ttlSec;
  const sig = await hmac(env.SESSION_SECRET, `media:${key}:${exp}`);
  return `${env.PUBLIC_URL}/m/${encodeURIComponent(key)}?exp=${exp}&sig=${sig}`;
}

export class HttpError extends Error {
  constructor(public status: number, public code: string, message: string) {
    super(message);
  }
}
