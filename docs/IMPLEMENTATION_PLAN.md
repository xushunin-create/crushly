# Crushly — Implementation Plan

Status: Phase 0 complete (2026-11-10). This file is the shared reference for the team; update it when a decision changes.

## 1. Current state (audit)

| Area | State before Phase 1 |
|---|---|
| Project | Single SwiftUI app target `Crushly`, iOS 26.0, Swift 5 mode, default MainActor isolation, Xcode file-system-synchronized folders (new files need no `project.pbxproj` edits). |
| UI | Static prototype: Around (decorative radar), Likes, Me/Safety, person sheet with "send pulse" heart animation. ~1.2k lines. |
| State | None. All counts, people and statuses hard-coded; toggles do nothing. |
| Backend | None. No Supabase config, no auth, no persistence. |
| Feedback | `PulseFeedbackManager` (AVAudioPlayer + UIKit haptics), `heartbeat.wav`, `signal.wav`. |
| Tests | None. |
| Build | Builds clean for iOS Simulator (Xcode 27.2). |

**Reusable:** visual language (cream / pink / lime palette, radar rings, heart button and expanding rings), feedback manager, sounds, screen decomposition.

**Must change:** the prototype radar shows compass directions and metre distances for fictional people. The spec forbids implying physical location, so radar placement becomes abstract and distances are removed (or labelled *simulated* in demo mode only).

## 2. Architecture

```
Crushly/
  App/            CrushlyApp, AppConfig (demo/live), AppState (single source of truth), RootView, routes
  DesignSystem/   Theme tokens (color, type, spacing, radius, motion), reusable components
  Models/         Domain value types shared by every module (no backend types leak past Services/)
  Services/
    Contracts.swift     Protocols: Auth, Profile, Spaces, Pulse, Signals, Matches(+Connections/Find), Safety, Notifications, Analytics
    Demo/               Deterministic in-memory backend that enforces the same rules as the server + scenarios
    Live/               Supabase implementations (supabase-swift), calling the RPCs in docs/BACKEND_CONTRACT.md
    Feedback/           Sound + haptics (respects Reduce Motion / silent preferences)
  Features/
    Onboarding/  Around/  Signals/  Profile/  Me/  HeartSync/  Connections/
supabase/
  migrations/     SQL schema, RLS, RPCs (server is the authority for every sensitive rule)
  functions/      Edge functions needing the service role (account deletion, push delivery)
  tests/          SQL tests run against a disposable Postgres
docs/
```

- **One state owner.** `AppState` (`@Observable`, MainActor) holds session, profile, pulse session, shield state, receipts, matches. Views read it and call intent methods; intent methods call services and then refresh from the service result. Views never call services directly.
- **One service boundary.** `Services` is a struct of protocol-typed services, built once from `AppConfig`. Demo and live never mix within a run.
- **Server is authoritative.** Clients send intents (`send_heart_signal`, `start_pulse`, ...). Eligibility, limits, anonymity, matching and expiry are decided in SQL `security definer` functions. The demo backend mirrors those rules in one Swift file (`DemoRules`) so behaviour matches; the SQL is the spec.
- **Environments.** `AppConfig` reads `SUPABASE_URL` / `SUPABASE_ANON_KEY` from `Config/Secrets.xcconfig` (git-ignored) via Info.plist keys. Missing → demo mode, with a persistent `DEMO` badge. Demo data never touches Supabase; live never shows demo profiles.

## 3. Product decisions and configurable defaults

All values live in the server table `app_settings` (and `AppRules.default` for demo). Clients display them; only the server enforces them.

| Rule | Default | Notes |
|---|---|---|
| Allowed email domains | `usc.edu` | Enforced by trigger on `auth.users` insert, and client-side for UX. |
| Auth flow | Passwordless email OTP (6-digit code) | Verifying the code = email verified. Recovery = request a new code. |
| Pulse durations | 30 min, 60 min, until event end | Event option only when the space has a future `ends_at`. |
| Paused | Hidden immediately; expiry clock keeps running; resume only if not expired | |
| Viewing Around | Requires your own live, unpaused Pulse | Reciprocity: no lurking. |
| Signals per Pulse session | 5 | |
| Signal validity | 72 h | Pending signals survive the sender's session ending. |
| Re-signal | Blocked while a pending signal to the same person exists | |
| Signal targets | Someone currently discoverable to you, or someone you encountered in Around in the last 24 h | Encounters recorded server-side; makes Crossed Hearts possible. |
| Match classification | Heart Sync if both are live, unpaused and in the same space at match time; otherwise Crossed Hearts | |
| One match per pair | Yes (a removed connection does not re-match) | |
| Receipt timing | Receipt becomes visible 2–10 min (random) after send; time shown rounded to 15 min | Prevents identifying the sender by timing. |
| Receipt space name | Shown only if ≥5 people were live in that space at send time | k-anonymity. |
| Connection confirmation | 24 h | Confirm = choose Met Tonight / Find Later / any accepted action. |
| Confirmed but inactive | 7 days | Activity = any connection action sent or answered. |
| Reminders | 1, 4 h before expiry | |
| Find request timeout | 10 min to accept; active Find Mode 30 min | |
| Shield durations | 1 h, 4 h, 24 h, until turned off | Leaving Shield never restarts Pulse. |
| Photos | Pending photos visible; rejected hidden; badge only when `approved` | Selfie verification: placeholder service, never shows a badge. |
| Distance | Not shown in live mode (no approximate-location implementation yet) | Demo shows "simulated" ranges only. |

## 4. Phases and revised estimates

| Phase | Scope | Estimate |
|---|---|---|
| 0 | Audit + plan | done |
| 1 | Foundation: tokens, components, 3 tabs, AppState, service contracts, demo backend, Supabase schema/RLS/RPCs, SQL tests | 2–3 d |
| 2 | OTP auth, domain/age/terms gates, session restore, profile create/edit, photo upload + review states | 3–4 d |
| 3 | Pulse Mode lifecycle, Campus Spaces + event codes, Around radar/list | 3–4 d |
| 4 | Heart Signal send, anonymous receipts, Heart Sync reveal | 4–5 d |
| 5 | Crossed Hearts, Signals sections, Connect Later actions, connection lifecycle, Find Each Other consent flow | 3–5 d |
| 6 | Me settings, Shield, block/report/unblock, account deletion | 3–4 d |
| 7 | Notification prefs, APNs delivery function, outbox/reminders, analytics | 3–5 d |
| 8 | Edge cases, accessibility pass, multi-account verification, release docs | 3–5 d |

Total ≈ 24–36 developer days. The prototype saves design time, not backend time.

## 5. External dependencies

| Dependency | Needed for | Owner |
|---|---|---|
| Supabase project (URL + anon key; service role kept server-side) | Live mode for every phase | Team |
| Supabase email templates with `{{ .Token }}` (OTP) | Phase 2 | Team |
| Apple Developer team, APNs auth key (.p8) | Phase 7 | Team |
| Terms of Service, Privacy Policy | Release (dev placeholders until then) | Legal |
| Moderation owner + review process | Phase 6 / release | Team |
| Selfie / identity verification vendor | Optional, post-launch | Team |

## 6. Team ownership

A: Onboarding, Profile, Me · B: Pulse, Spaces, Around · C: Signals UI, Heart Sync, motion/sound/haptics · D: Supabase, RPCs, Live services, integration. Everyone codes against `Services/Contracts.swift` and `docs/BACKEND_CONTRACT.md`.
