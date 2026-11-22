-- "Post now" for one platform while the other stays scheduled: a per-platform time that overrides publish_at.
ALTER TABLE items ADD COLUMN ig_due_at INTEGER;
ALTER TABLE items ADD COLUMN yt_due_at INTEGER;
