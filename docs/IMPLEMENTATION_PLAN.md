# Crushly — Implementation Plan

Status (2026-11-16): the Campus Spaces rework (Phases 1–6 of [CAMPUS_SPACES_DESIGN.md](CAMPUS_SPACES_DESIGN.md) §10)
is implemented and verified against the demo fixture, the SQL test suite and the iOS unit/UI tests. Live-mode journeys
have not been run against the real Supabase project yet. Launch blockers are listed in
[PRE_LAUNCH_CHECKLIST.md](PRE_LAUNCH_CHECKLIST.md).

This replaces the original Pulse / Around / Heart Signal plan (2026-11-10). Its architecture still holds; its product
rules do not.

## 1. Architecture

```
Crushly/
  App/            CrushlyApp (privacy cover), AppConfig (demo/live), AppState (single source of truth), RootView + tabs
  DesignSystem/   Theme tokens, components, shared cards, avatar
  Location/       Geometry, SpaceZone (+ bundled catalog), MembershipEngine (pure state machine), LocationService
  Models/         Domain types, server-configurable rules, errors
  Services/       Contracts.swift (protocols mirroring BACKEND_CONTRACT) · Live/ (Supabase) · Demo/ (dev fixture +
                  simulated location) · Chat/ (protected message cache) · Notifications/ · Feedback/
  Features/       Onboarding · Spaces · Connections · HeartSync · Safety · Privacy · Profile · Me
supabase/         migrations · seed · functions · tests (SQL, Docker)
```

- **One state owner.** `AppState` holds account, participation, discovery, conversations and chat threads. Views call
  intent methods; only AppState talks to the backend and to Core Location.
- **Server is authoritative.** Every privacy rule lives in `security definer` SQL with tests. The demo backend mirrors
  those rules in Swift for walkthroughs and unit tests; it is a labelled dev fixture, never a check-in bypass.
- **Location stays on the device.** `MembershipEngine` decides membership; the server only gets a space id, a consent
  epoch and evidence plausibility fields (fix time, age, accuracy, stationary), renewed on a 60 s lease.
- **Content-free realtime.** Private `user:<uid>` channels carry `{type, match_id}` pokes; clients refetch via RPCs.

## 2. Product rules (all server-configurable in `app_settings`)

| Rule | Default |
|---|---|
| Allowed email domains | `usc.edu` |
| Participation | When-In-Use location only; explicit "Open to matching" per visit; 60 s lease renewed every 20 s with fresh evidence |
| Evidence | accuracy ≤ 30 m; fix age ≤ 15 s (≤ 300 s re-cited while stationary); monotonic fix times and sequence numbers |
| Discovery | Own active session required; `quiet` below 2 participants (no counts); ≤ 8 random profiles; 1 call / 15 s, 60 / h |
| Interest | Only toward someone shown this visit; 5 per visit; anonymous receipt after 30–90 s; deleted when either session ends |
| Matching | Both live in the same space and boundary version, mutual preferences (gender + age), verified-only, no block, not paused |
| Chat | 1–2000 chars; 20 / min, 500 / day; retry-safe ids; leave & delete removes history for both |
| Pause | 1 h, 4 h, 24 h or until resumed; pausing revokes; resuming never opens a session |
| Report evidence | Only selected messages; 90 days; service role only |
| Notifications | `new_match`, `new_message`; generic lock-screen copy |

## 3. Phase log

| Phase | Scope | Result |
|---|---|---|
| 1 | Design + decisions | `CAMPUS_SPACES_DESIGN.md` |
| 2 | Migration: spaces, participation, interests, matches/messages, predicates, RPCs, rate limits, RLS | SQL suite |
| 3 | Location service, membership engine, GPX fixtures, draft zones | Engine + GPX unit tests |
| 4 | New contracts, Live + Demo backends, AppState participation/discovery/matching, consent sheet, Spaces UI | Flow + demo-rule unit tests |
| 5 | Chat, realtime pokes migration, leave & delete, block/report evidence, protected cache | `80_realtime.sql`, chat unit tests |
| 6 | Supported spaces + explainer, privacy settings, app-switcher cover, accessibility, UI test rewrite, docs | UI tests + audits |

## 4. What's left

See [PRE_LAUNCH_CHECKLIST.md](PRE_LAUNCH_CHECKLIST.md): production settings, field validation of every zone (plus
Founders Park and the Piazza), APNs, SMTP, edge function redeploys, pg_cron, legal text, moderation, and on-campus
device testing (latency, accuracy near buildings, background renewal, battery).
