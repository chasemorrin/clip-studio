-- Which login connected the account:
--   instagram = Business Login for Instagram (graph.instagram.com, 60-day tokens that get refreshed)
--   facebook  = Unified login / Facebook Login for Business (graph.facebook.com, system-user token that doesn't expire)
ALTER TABLE ig_accounts ADD COLUMN kind TEXT NOT NULL DEFAULT 'instagram';
