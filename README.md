# Crushly

An iOS app for USC students to see who's around in a Campus Space, send anonymous Heart Signals, and connect only when the interest is mutual.

SwiftUI · iOS 26 · Supabase (Postgres + RLS + Edge Functions) · Swift Testing / XCTest

---

## Quick start (demo mode, no setup)

1. Open `Crushly.xcodeproj` in Xcode 27 and run the **Crushly** scheme on an iPhone simulator.
2. With no `Secrets.plist`, the app runs in **demo mode**: a fictional campus, scripted people, a simulated clock and a permanent **DEMO** badge. Nothing is saved or sent anywhere.
3. Sign in with any `@usc.edu` address and the code **123456**.

Launch arguments (Product → Scheme → Edit Scheme → Arguments; already listed there, disabled):

| Argument | Effect |
|---|---|
| `-CrushlyDemo` | Force demo mode even if `Secrets.plist` exists |
| `-CrushlyDemoSeeded` | Start signed in with a finished profile ("Tommy") |
| `-CrushlyRoute signals` | Demo only: simulate tapping a notification (`signals`, `around`, `match:<id>`) |

## Demo walkthrough (about 5 minutes, repeatable)

Run with `-CrushlyDemo -CrushlyDemoSeeded`. **Me → Demo controls** has *Skip ahead*, *Simulate photo approval / rejection*, and a list of who does what.

1. **Around:** tap **Enter the Radius** → USC Village → 30 min. Seven people appear on the radar. The radar positions are labeled decorative; switch to **List**, where distances are labeled *simulated*.
   - Taylor (paused), Jordan (protected), Sam (verified-only) and Rio (another space) are correctly hidden.
2. **Anonymous receipt:** the **Signals** tab shows *"Someone nearby noticed you."* with a coarse time and no name.
3. **One-sided signal:** open **Noah** → **Send Heart Signal**. Heartbeat, rings and *"Sent privately."* Noah never signals back, so it stays anonymous. The card now reads *4 of 5 signals left*.
4. **Heart Sync:** open **Mina** → send. The profile closes and the full-screen reveal plays: *"You noticed each other. The feeling is mutual."*
5. **Find Each Other:** tap **Find Each Other Now** → Tommy Trojan. Mina accepts after a few seconds and Find Mode turns on (Signals → Mina). Tap **We found each other**.
6. **Delayed match:** signal **Alex** and close his profile. About 20 seconds later the reveal appears on its own, and Alex then asks to meet. Accept or decline it in Signals → Alex.
7. **Crossed Hearts:** Me → **Skip ahead 5 minutes** (Jamie leaves). In Around, under *Recently in your radius*, signal **Jamie**. The reveal reads *"You missed the moment, not each other."* Jamie then suggests coffee.
8. **Connect Later:** on any match, choose **Connect Later**, then *Swap Instagram*. The handle appears only after the other person accepts.
9. **Safety:** use **Protect My Heart** from the Pulse card. You vanish and leaving doesn't make you visible again. Block or report from any profile's ••• menu.
10. **Expiry:** Me → **Skip ahead 25 hours**. Unconfirmed connections move to *Expired*, and the Pulse card shows *"Time's up — you're hidden"*.

## Live mode (Supabase)

1. Copy `Config/Secrets.example.plist` to `Crushly/Resources/Secrets.plist` (git-ignored) and fill in the **Project URL** and **publishable / anon key**. Never put the service-role or secret key in the app.
2. In the Supabase SQL Editor, run in order:
   - `supabase/migrations/20261110000000_init.sql`
   - `supabase/migrations/20261111000000_notifications.sql`
   - `supabase/seed.sql`
3. **Authentication → Email Templates → Magic Link:** include `{{ .Token }}`, because the app expects a 6-digit code.
4. **Email delivery:** Supabase's built-in mailer only sends to organization members and is rate-limited. For real users, configure custom SMTP (needs a domain). For testing, invite your own USC address to the Supabase org.
5. **Edge Functions:** deploy `delete-account` (Verify JWT on) and, once APNs is ready, `push-dispatch` (Verify JWT off). See [docs/NOTIFICATIONS.md](docs/NOTIFICATIONS.md).
6. Optional: enable `pg_cron` before running the migration so expiry cleanup and reminders run every minute.

## Tests

```bash
# App: unit + UI tests (demo backend), ~15 min
xcodebuild test -project Crushly.xcodeproj -scheme Crushly \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro'

# Database: schema, RLS, RPCs, anonymity, concurrency (needs Docker), ~2 min
supabase/tests/run.sh
```

| Suite | What it covers |
|---|---|
| `CrushlyTests` (Swift Testing) | Onboarding gates, profile validation, the demo rules mirror of the server (limits, duplicates, anonymity, one match per pair, Heart Sync vs Crossed Hearts, blocks, Shield, expiry), connection lifecycle, Find Each Other, notification routing |
| `CrushlyUITests` (XCTest) | End-to-end journeys for every phase, plus Apple's accessibility audit at default and the largest text size |
| `supabase/tests` (SQL) | 246 assertions across 11 suites, including the recipient being unable to read signal rows, reciprocal sends from two connections producing exactly one match, and send-time notification suppression |

## Project layout

```
Crushly/
  App/            Entry point, AppConfig (demo/live), AppState (single source of truth), RootView + tab bar
  DesignSystem/   Theme tokens, components, avatar
  Models/         Domain types, rules/defaults, errors
  Services/       Contracts.swift (protocols) · Demo/ (in-memory server + fictional cast) · Live/ (Supabase) ·
                  Feedback/ (sound + haptics) · Notifications/ (permission, APNs registration, deep links)
  Features/       Onboarding · Around · Signals · HeartSync · Connections · Safety · Me · Profile
CrushlyTests/ CrushlyUITests/
supabase/         migrations · seed · functions (delete-account, push-dispatch) · tests
docs/             IMPLEMENTATION_PLAN · BACKEND_CONTRACT · MODERATION · NOTIFICATIONS
```

## Status

### Implemented and verified (demo backend + SQL tests)

| Area | Covered |
|---|---|
| Registration | USC-only passwordless email code, 18+ declaration, Terms and Privacy acceptance, sign out, session restore, account deletion |
| Profiles | Photos (≤6, re-encoded with location metadata stripped), first name, age, pronouns, gender, exactly 3 interests, vibe tags, prompt, intention, availability, private Instagram |
| Photo review | Pending / approved / rejected states. A badge only appears when approved. Changing photos sends them back to review. |
| Pulse Mode | 30 / 60 min or until the event ends; pause (hidden, clock keeps running) and resume; expiry; server timestamps are authoritative |
| Campus Spaces | Manual places, events with end times, event codes |
| Around | Abstract radar with a stable per-session layout, list view, recent encounters, honest empty and expired states |
| Heart Signals | 5 per session, no repeats, no self-signals, eligibility enforced on the server, anonymous receipts (2–10 min delay, 15-min time buckets, space name shown only when ≥5 people were there) |
| Heart Sync / Crossed Hearts | Atomic match creation with concurrency tested, full-screen reveal, bell sound plus two haptic pulses, both classifications |
| Connections | Connect Later; coffee, study break, starter and Instagram requests with accept/decline; 24 h confirmation and 7 days of inactivity before expiry; remove |
| Find Each Other | Request → accept, public meeting points, timeout, cancel, complete. Ends if either person turns off Pulse, enters Shield or blocks. No location shared. |
| Safety | Protect My Heart (timed or indefinite, never auto-resumes), block and unblock, reports in 7 categories (reporting also blocks), safety tips |
| Notifications | Server queue with dedupe and send-time relevance checks, discreet copy, permission asked after the first signal, deep links, local Pulse reminder |
| Accessibility | Dynamic Type up to AX5 with no clipping, VoiceOver labels and hints, Reduce Motion, 44 pt targets, and the automated audit passing on the main screens |

### Simulated (demo mode only, clearly labeled)

- The fictional people and their behavior, the clock (*Skip ahead*), photo moderation decisions, and distance bands (labeled "(simulated)").
- Demo data resets when the app relaunches.

### Not verified or blocked

| Item | Blocked on |
|---|---|
| Any live-mode journey (sign-in, profile save, upload, Pulse, signals against Supabase) | Email delivery (custom SMTP, or org-member testing) |
| `delete-account` and `push-dispatch` edge functions: written, never run or type-checked | Deploying from the Supabase dashboard |
| Real push notifications | APNs key, the Push Notifications capability in Xcode, `push-dispatch` deployment and the cron schedule |
| Storage policies, `pg_cron` and the `auth.users` trigger on real Supabase | Only exercised on plain Postgres with stand-ins so far |
| Haptics and sound feel | Needs a physical iPhone (the simulator has no haptics) |
| Selfie / identity verification | A vendor (UI says "not available yet"; no badge) |
| Distance-based discovery | A real approximate-location design (deliberately not built) |
| Campus events notifications | An event data source |
| Terms of Service and Privacy Policy | Legal text (development placeholders, clearly marked) |
| Moderation | A named owner and review process ([docs/MODERATION.md](docs/MODERATION.md)) |

## Remaining launch work (revised estimate)

| Work | Estimate |
|---|---|
| Live integration pass: SMTP, two real accounts, fix whatever real Supabase surfaces (RLS, storage, PostgREST encoding) | 2–3 days |
| APNs end to end on devices, TestFlight build | 1–2 days |
| Realtime subscriptions to replace 8-second polling (optional) | 1 day |
| Admin / moderation tooling beyond SQL | 2–4 days |
| Legal text, App Store privacy labels, review notes (dating app, 18+) | external, plus about 1 day |

About **6–10 developer days** to a TestFlight beta with real users, plus external dependencies. App Store review for a dating app adds its own lead time.
