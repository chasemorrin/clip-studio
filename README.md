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

## Connect Instagram (when we get to auto-posting)

Your Instagram must be a Creator or Business account.

1. Go to developers.facebook.com → My Apps → Create app. Choose the use case for managing content on Instagram (Meta renames these screens now and then).
2. In the app, open Instagram → API setup with Instagram login.
3. Under Business login settings, add this OAuth redirect URI: `https://<your server>/instagram/callback`
4. Add your own Instagram account as an Instagram tester, then accept the invite in the Instagram app (Settings → Website permissions → Apps and websites, or the tester invites screen).
5. Copy the Instagram app ID and Instagram app secret:
   - App ID → `IG_APP_ID` in `wrangler.toml`
   - Secret → `npx wrangler secret put IG_APP_SECRET`
6. `npx wrangler deploy`

For your own account this works without Meta's app review. Other people's accounts need app review and business verification (App Store phase).

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
