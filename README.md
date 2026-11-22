# Clip Studio

An iPhone app for musicians: pick concert or practice footage, let Claude suggest clips, approve them, and have them post to Instagram on schedule. It also holds your posting calendar, idea bank and a home-screen widget.

- `server/`: Cloudflare Worker (sign-in, planner sync, Claude, clip storage, Instagram auto-posting). Tested end to end with `npm test`.
- `ios/`: SwiftUI iPhone app. Version 0.1 finds and exports clips.

Working name; rename any time.

## Deploy the server (about 15 minutes, on your Mac)

You need a free Cloudflare account and Node.js (`brew install node` if you don't have it).

```bash
cd server
npm install
npx wrangler login                      # opens Cloudflare in your browser
npx wrangler d1 create clip-studio      # prints a database_id
```

Paste that `database_id` into `server/wrangler.toml`, then:

```bash
npx wrangler r2 bucket create clip-studio-media
npx wrangler d1 migrations apply clip-studio --remote

openssl rand -base64 48 | npx wrangler secret put SESSION_SECRET
npx wrangler secret put ANTHROPIC_API_KEY   # paste your Claude API key
npx wrangler secret put DEV_LOGIN_KEY       # make up a password; used for testing before Sign in with Apple
npx wrangler deploy
```

`deploy` prints your server address, like `https://clip-studio.<your-name>.workers.dev`. Put it in `PUBLIC_URL` in `wrangler.toml` and run `npx wrangler deploy` again.

Check it: open the address in a browser. You should see `{"ok":true,"name":"clip-studio"}`.

## Build the iPhone app

You need Xcode and XcodeGen, a small tool that creates the Xcode project from `ios/project.yml`:

```bash
brew install xcodegen
cd ios
xcodegen
open ClipStudio.xcodeproj
```

Run `xcodegen` again whenever you pull changes that add or remove files.

In Xcode:
1. Click the ClipStudio project, then the ClipStudio target, then Signing & Capabilities. Choose your Team (your Apple ID works before the Developer Program is active). To skip this step next time, put your Team ID in `DEVELOPMENT_TEAM` in `ios/project.yml`.
2. Plug in your iPhone and pick it as the run destination at the top of the window.
3. Press Run (⌘R). The first time, the iPhone asks you to turn on Developer Mode (Settings → Privacy & Security → Developer Mode) and to trust your developer certificate (Settings → General → VPN & Device Management).
4. In the app, sign in with your test password (the `DEV_LOGIN_KEY` you set on the server).

Sign in with Apple works once you're in the Apple Developer Program: uncomment the `applesignin` line in `ios/project.yml` and run `xcodegen` again.

## Connect Instagram (for auto-posting)

Your Instagram must be a Creator or Business account. Newer Meta apps use **Unified login**, which goes through Facebook's login screen and gives a token that doesn't expire. Meta renames dashboard screens now and then, so labels may differ slightly.

1. developers.facebook.com → **My Apps → Create app**, use case **Manage messaging & content on Instagram**.
2. Connect a **business portfolio** when asked (free; create one under your name).
3. Use case → **Customize** → **API setup with Unified login**.
4. **Create new configuration**: system-user access token, Instagram account as the asset, permissions including `instagram_basic` and `instagram_content_publish`.
5. **Redirect URL**: register `https://clip-studio.chasemorrin.workers.dev/instagram/callback` and save.
6. Copy the **Login URL** Meta generates and paste it into `IG_LOGIN_URL` in `server/wrangler.toml`.
7. App settings → Basic → **App secret** → `npx wrangler secret put IG_APP_SECRET` and paste it.
8. From the `server` folder:
   ```bash
   npx wrangler d1 migrations apply clip-studio --remote
   npx wrangler deploy
   ```
9. In the iPhone app: **Settings → Connect Instagram**, log in, and select your Instagram account.

Privacy callbacks for Meta (needed before publishing the app):
- Deauthorize callback: `https://clip-studio.chasemorrin.workers.dev/instagram/deauthorize`
- Data deletion request: `https://clip-studio.chasemorrin.workers.dev/instagram/data-deletion`

Older apps with "API setup with Instagram login" also work: leave `IG_LOGIN_URL` empty and set `IG_APP_ID` to the Instagram app ID instead.

For your own account no app review is needed. Other people's accounts need app review and business verification (App Store phase).

## Connect YouTube (Shorts)

1. In Google Cloud (project "Clip Studio"), enable **YouTube Data API v3**.
2. Google Auth Platform: External audience, app name "Clip Studio", home/privacy/terms links to this server, scopes `youtube.upload` and `youtube.readonly`, then **Publish app** (In production) so logins don't expire after 7 days.
3. Clients → Create client → Web application, redirect URI `https://<your server>/youtube/callback`.
4. On your Mac:

```bash
cd server
npx wrangler secret put GOOGLE_CLIENT_ID
npx wrangler secret put GOOGLE_CLIENT_SECRET
npx wrangler d1 migrations apply clip-studio --remote
npx wrangler deploy
```

5. In the app: Settings → YouTube Shorts → Connect YouTube.

Until Google approves the app in its YouTube API audit, YouTube keeps every upload private; make each one public in the YouTube app. Set `CONTACT_EMAIL` in `wrangler.toml` so the homepage and privacy policy show a contact.

## Costs

Cloudflare's free tier covers this at personal volume (100k requests a day, 10 GB clip storage, free downloads). Clips are deleted after they post. The Claude API is billed per use in the Anthropic Console; the server caps it at `CLAUDE_DAILY_LIMIT` requests per person per day.

## Server API (for the app)

All `/v1` routes need `Authorization: Bearer <token>` except sign-in.

| Route | Purpose |
| --- | --- |
| `POST /v1/auth/apple` `{identityToken}` | Sign in with Apple → `{token}` |
| `POST /v1/auth/dev` `{key}` | Test sign-in (only if `DEV_LOGIN_KEY` is set) |
| `GET /v1/me` / `DELETE /v1/me` | Profile and Instagram status / delete account and all data |
| `GET /v1/items?since=` | Planner items changed since a time |
| `POST /v1/items` / `PATCH /v1/items/:id` / `DELETE /v1/items/:id` | Create / edit / delete. Fields: `title pillar format date status notes plan caption media coverMs publishAt autoPost` |
| `POST /v1/items/:id/retry` | Retry a failed auto-post |
| `PUT /v1/media` (body = file, `Content-Type` video/mp4, video/quicktime or image/jpeg) | Upload → `{key, type}` |
| `DELETE /v1/media/:key` | Remove an upload |
| `POST /v1/claude` `{system, messages, maxTokens}` | Ask Claude → `{text}` |
| `GET /v1/instagram/connect` | Instagram login URL (open in `ASWebAuthenticationSession`, callback scheme `clipstudio`) |
| `POST /v1/instagram/disconnect` | Forget the Instagram connection |

Auto-posting: set `media`, `publishAt` (Unix seconds) and `autoPost: true`. Every 5 minutes the server posts anything due. `postState` moves `queued → publishing → posted` (carousels pass through `children`), or `failed` with `postError`.
