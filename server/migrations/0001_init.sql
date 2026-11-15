-- People who use the app. apple_sub is Apple's stable user id.
CREATE TABLE users (
  id TEXT PRIMARY KEY,
  apple_sub TEXT UNIQUE,
  created_at INTEGER NOT NULL,
  claude_day TEXT,
  claude_count INTEGER NOT NULL DEFAULT 0
);

-- One connected Instagram account per user.
CREATE TABLE ig_accounts (
  user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  ig_user_id TEXT NOT NULL,
  username TEXT,
  access_token TEXT NOT NULL,
  token_issued_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

-- Short-lived values that tie an Instagram login back to the user who started it.
CREATE TABLE oauth_states (
  state TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at INTEGER NOT NULL
);

-- Planner items: ideas, scheduled posts and posted posts.
--   status:     idea | planned | filmed | edited | posted        (the planner's own status)
--   post_state: NULL | queued | children | publishing | posted | failed  (auto-posting)
CREATE TABLE items (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  title TEXT NOT NULL DEFAULT '',
  pillar TEXT NOT NULL DEFAULT 'live',
  format TEXT NOT NULL DEFAULT 'reel',
  date TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'idea',
  notes TEXT NOT NULL DEFAULT '',
  plan TEXT,
  caption TEXT NOT NULL DEFAULT '',
  media TEXT NOT NULL DEFAULT '[]',
  cover_ms INTEGER,
  publish_at INTEGER,
  post_state TEXT,
  ig_children TEXT,
  ig_container_id TEXT,
  ig_media_id TEXT,
  ig_permalink TEXT,
  post_error TEXT,
  post_attempts INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE INDEX items_user ON items(user_id, date);
CREATE INDEX items_due ON items(post_state, publish_at);

-- Uploaded clips and images, so a user can only attach their own files.
CREATE TABLE media (
  key TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  content_type TEXT NOT NULL,
  size INTEGER NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE INDEX media_user ON media(user_id);
