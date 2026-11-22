import { Env, cleanupIfDone, nowSec, signedMediaUrl } from "./util";
import { runYouTube } from "./youtube";
import { IgAccount, IgError, containerStatus, createContainer, publishContainer, refreshTokens } from "./instagram";

interface MediaRef { key: string; type: "video" | "image"; }
interface Row {
  id: string; user_id: string; format: string; caption: string; media: string; cover_ms: number | null;
  post_state: string; ig_children: string | null; ig_container_id: string | null; post_attempts: number;
}

const MAX_WAIT_CHECKS = 15;   // ~75 minutes of 5-minute checks while Instagram processes a video
const MAX_RETRIES = 6;        // temporary errors (Instagram down, rate limit)

async function account(env: Env, userId: string) {
  return env.DB.prepare("SELECT * FROM ig_accounts WHERE user_id = ?").bind(userId).first<IgAccount>();
}

async function update(env: Env, id: string, fields: Record<string, unknown>) {
  const keys = Object.keys(fields);
  await env.DB.prepare(`UPDATE items SET ${keys.map((k) => `${k} = ?`).join(", ")}, updated_at = ? WHERE id = ?`)
    .bind(...keys.map((k) => fields[k] ?? null), nowSec(), id).run();
}

const fail = (env: Env, id: string, msg: string) => update(env, id, { post_state: "failed", post_error: msg });

async function step(env: Env, row: Row): Promise<void> {
  const acct = await account(env, row.user_id);
  if (!acct) return fail(env, row.id, "Connect your Instagram account in Settings, then schedule this again.");
  if (acct.expires_at < nowSec()) return fail(env, row.id, "Your Instagram connection expired. Reconnect it in Settings, then schedule this again.");
  const media: MediaRef[] = JSON.parse(row.media || "[]");
  const caption = row.caption || "";

  if (row.post_state === "queued") {
    if (!media.length) return fail(env, row.id, "There's no clip or photo attached to this post.");
    if (row.format === "carousel") {
      if (media.length < 2) return fail(env, row.id, "A carousel needs at least 2 photos or clips.");
      const children: string[] = [];
      for (const m of media.slice(0, 10)) {
        const url = await signedMediaUrl(env, m.key);
        const c = await createContainer(env, acct, m.type === "video"
          ? { is_carousel_item: "true", media_type: "VIDEO", video_url: url }
          : { is_carousel_item: "true", image_url: url });
        children.push(c.id);
      }
      return update(env, row.id, { post_state: "children", ig_children: JSON.stringify(children), post_attempts: 0, post_error: null });
    }
    const m = media[0];
    const url = await signedMediaUrl(env, m.key);
    const params: Record<string, string> = m.type === "video"
      ? { media_type: "REELS", video_url: url, caption, share_to_feed: "true", ...(row.cover_ms != null ? { thumb_offset: String(row.cover_ms) } : {}) }
      : { image_url: url, caption };
    const c = await createContainer(env, acct, params);
    return update(env, row.id, { post_state: "publishing", ig_container_id: c.id, post_attempts: 0, post_error: null });
  }

  if (row.post_state === "children") {
    const ids: string[] = JSON.parse(row.ig_children || "[]");
    const states = await Promise.all(ids.map((id) => containerStatus(env, acct, id)));
    if (states.some((s) => s.status_code === "ERROR" || s.status_code === "EXPIRED")) {
      return fail(env, row.id, "Instagram couldn't process one of the carousel files. Check the format and try again.");
    }
    if (!states.every((s) => s.status_code === "FINISHED")) {
      if (row.post_attempts + 1 >= MAX_WAIT_CHECKS) return fail(env, row.id, "Instagram took too long to process the carousel. Try again.");
      return update(env, row.id, { post_attempts: row.post_attempts + 1 });
    }
    const c = await createContainer(env, acct, { media_type: "CAROUSEL", children: ids.join(","), caption });
    return update(env, row.id, { post_state: "publishing", ig_container_id: c.id, post_attempts: 0 });
  }

  if (row.post_state === "publishing" && row.ig_container_id) {
    const s = await containerStatus(env, acct, row.ig_container_id);
    if (s.status_code === "ERROR" || s.status_code === "EXPIRED") {
      return fail(env, row.id, `Instagram couldn't process the video${s.status ? ` (${s.status})` : ""}.`);
    }
    if (s.status_code !== "FINISHED" && s.status_code !== "PUBLISHED") {
      if (row.post_attempts + 1 >= MAX_WAIT_CHECKS) return fail(env, row.id, "Instagram took too long to process the video. Try again.");
      return update(env, row.id, { post_attempts: row.post_attempts + 1 });
    }
    const p = await publishContainer(env, acct, row.ig_container_id);
    await update(env, row.id, { post_state: "posted", status: "posted", ig_media_id: p.id, ig_permalink: p.permalink || null, post_error: null });
    // Free the storage, unless YouTube still needs the file.
    await cleanupIfDone(env, row.id);
  }
}

export async function runPublisher(env: Env): Promise<{ processed: number; refreshed: number; youtube: number }> {
  const refreshed = await refreshTokens(env);
  const { results } = await env.DB.prepare(
    `SELECT id, user_id, format, caption, media, cover_ms, post_state, ig_children, ig_container_id, post_attempts FROM items
     WHERE (post_state = 'queued' AND publish_at <= ?) OR post_state IN ('children', 'publishing')
     ORDER BY publish_at LIMIT 25`
  ).bind(nowSec()).all<Row>();
  for (const row of results) {
    try {
      await step(env, row);
    } catch (e) {
      if (e instanceof IgError && e.transient && row.post_attempts + 1 < MAX_RETRIES) {
        await update(env, row.id, { post_attempts: row.post_attempts + 1, post_error: `Retrying: ${e.message}` });
      } else {
        await fail(env, row.id, e instanceof Error ? e.message : String(e));
      }
    }
  }
  const youtube = await runYouTube(env);
  return { processed: results.length, refreshed, youtube };
}
