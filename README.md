# Crushly

An iOS app for USC students. When you're in a supported campus space, you can choose — for that visit only — to be
open to matching with other people there who made the same choice. Interest stays private unless it's mutual; mutual
interest becomes a one-to-one chat.

Your location is evaluated on your iPhone. The server only learns which space you chose, on a 60-second lease.
Nobody else ever sees your location, distance, arrival, online status or how many people are around. Crushly is not
anonymous, not end-to-end encrypted, and not affiliated with or endorsed by USC.

SwiftUI · iOS 26 · Core Location (When In Use) · Supabase (Postgres + RLS + Realtime + Edge Functions) ·
Swift Testing / XCTest

Design: [docs/CAMPUS_SPACES_DESIGN.md](docs/CAMPUS_SPACES_DESIGN.md) · Server contract:
[docs/BACKEND_CONTRACT.md](docs/BACKEND_CONTRACT.md) · Launch blockers: [docs/PRE_LAUNCH_CHECKLIST.md](docs/PRE_LAUNCH_CHECKLIST.md)

---

## Quick start (demo mode, no setup)

1. Open `Crushly.xcodeproj` in Xcode and run the **Crushly** scheme on an iPhone simulator.
2. With no `Secrets.plist`, the app runs the **demo fixture**: fictional people, a simulated location, a simulated
   clock and a permanent **DEMO** badge. It is in-memory only and can never reach the server.
3. Sign in with any `@usc.edu` address and the code **123456**.

| Launch argument | Effect |
|---|---|
| `-CrushlyDemo` | Force demo mode even if `Secrets.plist` exists |
| `-CrushlyDemoSeeded` | Start signed in with a finished profile and preferences ("Tommy") |
| `-CrushlyDemoLocation <slug\|outside>` | Demo only: start the simulated location in a zone (`upc-mccarthy-quad`, `usc-village-great-lawn`, `upc-alumni-park-tommy-trojan`) |
| `-CrushlyDemoLocationAuth <precise\|approximate\|denied\|notDetermined>` | Demo only: simulated permission |
| `-CrushlyRoute <connections\|match:<id>>` | Demo only: simulate tapping a notification |

### Demo walkthrough (about 5 minutes)

Run with `-CrushlyDemo -CrushlyDemoSeeded -CrushlyDemoLocation upc-mccarthy-quad`. **Me → Demo controls** moves the
simulated location, changes the simulated permission, skips time, simulates photo review and lists what each person does.

1. **Spaces → Turn on campus matching.** After two stable fixes (~8 s) the sheet asks *"Open to matching here?"*.
   Try **Stay invisible** first: the status card says so, and you won't be asked again this visit.
2. **Open to matching here.** Seven people appear in random order. Taylor (paused), Jordan (his preferences exclude
   you), Sam (verified-only) and Rio (another space) never appear.
3. **"Someone here is interested"** appears with no name, time or count detail (that's Mina).
4. **Private interest:** open **Noah** → **I'm interested**. He never reciprocates; nothing is revealed.
5. **Heart Sync:** open **Mina** → **I'm interested** → the reveal → **Send a message**. She replies.
6. **Delayed match:** show interest in **Alex**; about 20 s later the reveal appears on its own.
7. **Leaving deletes interests:** Jamie shows interest, then leaves after 3 minutes; their interest is gone with them.
8. **Leave the space** (Demo controls → *Outside*): you're revoked immediately. **Skip ahead 2 minutes** while inside:
   the lease lapses and you're asked again.
9. **Quiet space:** move to *Great Lawn at USC Village*: "It's quiet here", with no count.
10. **Safety:** in a chat, ••• → *Report or block* (choose messages as evidence) or *Leave & delete conversation*.
    Me → *Privacy & safety* → *Pause campus matching*.

## Live mode (Supabase)

1. Copy `Config/Secrets.example.plist` to `Crushly/Resources/Secrets.plist` (git-ignored) with the **Project URL** and
   **anon / publishable key**. Never put the service-role key in the app.
2. Apply the migrations in order in the SQL Editor: `20261110000000_init`, `20261111000000_notifications`,
   `20261116000000_campus_spaces`, `20261117000000_draft_usc_spaces`, `20261118000000_realtime_pokes`, then `seed.sql`.
3. For development only, enable draft zones: `update app_settings set value = 'true' where key = 'allow_draft_spaces';`
   (production must keep `false`).
4. Realtime → Settings: turn off **Allow public access**. Auth: OTP email template with `{{ .Token }}`; custom SMTP for
   real users.
5. Deploy `delete-account` (Verify JWT on) and `push-dispatch` (Verify JWT off) — see [docs/NOTIFICATIONS.md](docs/NOTIFICATIONS.md).
6. On a simulator, test locations with the GPX routes in `Config/Locations/` (Scheme → Run → Options → Default
   Location) or `xcrun simctl location booted start …`.

## Tests

```bash
# App: unit tests (~2 min) and UI tests incl. accessibility audits (~10 min), demo fixture only
xcodebuild test -project Crushly.xcodeproj -scheme Crushly -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -only-testing:CrushlyTests
xcodebuild test -project Crushly.xcodeproj -scheme Crushly -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -only-testing:CrushlyUITests

# Database: schema, RLS, RPCs, privacy rules, realtime authorization, concurrency (needs Docker, ~2 min)
bash supabase/tests/run.sh
```

| Suite | What it covers |
|---|---|
| `CrushlyTests` | Membership engine + GPX replays; participation flow through AppState (consent, open/renew/revoke, lease loss, reconciliation, pause, sign-out); demo-rule mirror of the SQL (evidence, epochs, quiet spaces, two-way preferences, exposure-gated interest, cascades, blocks); chat (paging, retry-safe sends, leave & delete, report evidence, cache protection and purging, pokes); privacy guards (no logging in location/chat/backend code, no coordinates in evidence, photos stripped of GPS); onboarding; notification routing |
| `CrushlyUITests` | Onboarding with preferences; consent / stay invisible / open / interest / Heart Sync / chat; go invisible; quiet space; outside; permission states; explainer; leave & delete; block from chat; notification route; pause; Apple's accessibility audit at default and AX5 |
| `supabase/tests` | Every privacy rule in design §5–7, plus `80_realtime.sql`: own private channel only, receive-only, content-free pokes, and no message content reaching a still-connected subscriber after block, leave or account deletion |

## Project layout

```
Crushly/
  App/            CrushlyApp (privacy cover), AppConfig, AppState, RootView + tabs (Spaces / Connections / Me)
  DesignSystem/   Theme, components, shared cards, avatar
  Location/       Geometry, SpaceZone, MembershipEngine, LocationService
  Models/         Domain types, rules, errors
  Services/       Contracts · Live (Supabase) · Demo (fixture + simulated location) · Chat (message cache) ·
                  Notifications · Feedback
  Features/       Onboarding · Spaces · Connections · HeartSync · Safety · Privacy · Profile · Me
  Resources/      campus_spaces.json (bundled draft zones, © OpenStreetMap contributors)
supabase/         migrations · seed · functions · tests
docs/             CAMPUS_SPACES_DESIGN · BACKEND_CONTRACT · PRE_LAUNCH_CHECKLIST · IMPLEMENTATION_PLAN · NOTIFICATIONS · MODERATION
```

## Status

Implemented and verified against the demo fixture, the SQL suite (plain Postgres with Supabase stand-ins) and the iOS
simulator. **Not yet verified:** any journey against the live Supabase project, real Realtime/APNs delivery, and
on-campus behaviour (entry/exit latency, accuracy near buildings, background renewal, battery). All three campus zones
are unvalidated drafts. See [docs/PRE_LAUNCH_CHECKLIST.md](docs/PRE_LAUNCH_CHECKLIST.md).
