-- One connected YouTube channel per user (Google sign-in).
CREATE TABLE yt_accounts (
  user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  channel_id TEXT,
  channel_title TEXT,
  channel_handle TEXT,
  refresh_token TEXT NOT NULL,
  access_token TEXT,
  access_expires_at INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL
);

-- YouTube posting, tracked separately from Instagram's post_state.
--   yt_state: NULL | queued | uploading | posted | failed
ALTER TABLE items ADD COLUMN yt_state TEXT;
ALTER TABLE items ADD COLUMN yt_title TEXT;
ALTER TABLE items ADD COLUMN yt_video_id TEXT;
ALTER TABLE items ADD COLUMN yt_privacy TEXT;
ALTER TABLE items ADD COLUMN yt_error TEXT;
ALTER TABLE items ADD COLUMN yt_attempts INTEGER NOT NULL DEFAULT 0;
ALTER TABLE items ADD COLUMN yt_started_at INTEGER;
CREATE INDEX items_yt_due ON items(yt_state, publish_at);
