# Campus Spaces & Private Matching: Design (Phase 1)

Status: **draft for approval** (2026-11-16). Nothing in the app or database has changed yet.
This document replaces the Pulse / Around / Crossed Hearts / Find Each Other model described in
`IMPLEMENTATION_PLAN.md` and `BACKEND_CONTRACT.md`. Those files will be updated in the phase that implements each part.

Scope decisions already made: **no end-to-end encryption in this version** (deferred by product decision; see §8.4).

---

## 1. Audit: what exists and what conflicts

Baseline on 2026-11-16: all unit tests pass; SQL suite 11/11 suites, 246 assertions pass (`supabase/tests/run.sh`, Docker Postgres 16).

**Keep (reuse as-is or nearly):**

| Area | Why it stays |
|---|---|
| Auth: passwordless USC email OTP, domain trigger, age ≥ 18 + age confirmation, terms gate | Already matches the spec. |
| Profiles + `profile_private`, photo review states, owner-only RLS | Already avoids leaking private fields. |
| Photo pipeline | `ProfileEditorView` re-encodes to JPEG from a bitmap, which drops EXIF/GPS. Will add a test that proves it. |
| Server-authoritative architecture: `security definer` RPCs, deny-by-default grants, error codes | This is the right foundation for "enforce on the backend". |
| Blocks, reports, `delete-account` edge function, notification outbox + `push-dispatch` | Extend, don't replace. |
| Design system, tab bar, feedback sounds/haptics, Heart Sync reveal animation | Brand personality. The reveal stays for new matches. |
| Demo backend pattern (`DemoBackend` mirrors SQL rules) | Becomes the simulator/dev fixture for the new model. |

**Remove or replace (conflicts with the privacy spec):**

| Existing feature | Problem | Replacement |
|---|---|---|
| `RadarView`, simulated distance bands, `PublicProfile.simulatedDistanceBand` | Radar/proximity imagery and distance | Card-based candidate list, no position or distance |
| Manual space picker + `enter_space_code` / `space_codes` | Lets anyone check in remotely | Spaces can only be joined from device location evidence |
| `pulse_sessions` (30/60 min / until event end, pause/resume) | Long-lived visibility, not tied to location | 60 s leased **participation sessions** (§4) |
| `encounters` table, `recent_encounters()`, "Recently in your radius" | History of crossed paths | Deleted outright |
| Crossed Hearts matches (match after one person left) | Delayed record of shared whereabouts | Matches require both to be live in the same space at match time |
| `heart_signals.space_id`, 72 h validity, `space_disclosable`, receipt `space_name` | Interests become a record of where someone was | Interests tied to sessions; deleted when either session ends (§5.3) |
| `matches.space_id`, `my_matches().space_name` | Match-location history | No place stored on matches |
| `public_profile.space_id / space_name / session_paused` | Shows another person's current space and status | Removed from the composite |
| Find Each Other (`find_requests.meeting_point`, Find Mode) | Coordinates meeting at a named spot; reveals location | Removed (chat covers coordination if both want it) |
| Push copy "Someone nearby felt a spark." | Notification implies presence nearby | Generic copy only (§7.3) |
| `around_profiles()` stable hash order, unlimited result set | Stable ordering + full export of a space | Random sample, capped and rate-limited (§5.2) |
| Shield ("Protect My Heart") | Same idea as the spec's global pause | Renamed and reused as **Pause campus matching** |

**Missing entirely:** Core Location (no CL code or Info.plist keys today), chat/messages, realtime, matching preferences ("show me"), rate limiting beyond per-session signal counts, app-switcher privacy cover, local cache protection.

---

## 2. Location: what iOS actually gives us

Verified against Apple documentation (CLMonitor, CLLocationUpdate, CLServiceSession, CLBackgroundActivitySession, authorization and background articles; WWDC23 10147/10180, WWDC24 10212). No Core Location changes were found for iOS 26.

| Fact | Consequence for design |
|---|---|
| `CLMonitor` allows at most 20 conditions per app; geofence entry/exit averages **3 to 5 minutes** on the legacy API, and no tighter figure is documented for CLMonitor | Geofences are only a coarse "you might be near a space" trigger, never evidence. **Phase 3: not used at all.** With When-In-Use only (decision Q1), iOS won't relaunch the app for geofences, and while the app is open `liveUpdates` is both faster and sufficient |
| Region monitoring is unavailable with **approximate location**; approximate fixes are 1 to 20 km and update a few times an hour | Approximate location means "can't verify", with a request for temporary precise access |
| Relaunch after termination on a geofence needs **Always** plus an explicit `.always` `CLServiceSession` started in the foreground | Detecting arrival while the app is closed needs Always (optional, see §9 Q1) |
| `CLBackgroundActivitySession` lets a **When-In-Use** app keep getting `liveUpdates` in the background (blue location indicator); it must be started in the foreground | Participation can keep renewing while the app is backgrounded, visibly |
| `liveUpdates` **pauses when the device is stationary** (`isStationary`/`stationary` flag) | Sitting still produces no new fixes; see the stationary rule in §3.3 |
| After a relaunch, Core Location remembers sessions only "for a few seconds"; loops must be re-created immediately at launch | Location service is started in `application(_:didFinishLaunchingWithOptions:)`, not lazily in a view |
| Monitoring resumes only after first unlock following a reboot | After a restart, nothing happens until unlock; any old lease has long expired |

Permissions requested progressively:

1. **None** at sign-up. Chats, matches and profile work with no location permission.
2. **When In Use**: requested the first time the user opens the Spaces tab and taps "Turn on campus matching", after a one-screen explanation.
3. **Temporary full accuracy**: requested only if the user chose approximate location, via `CLServiceSession(authorization: .whenInUse, fullAccuracyPurposeKey:)`.
4. **Always**: only if we ship the optional "notify me when I arrive" feature (§9 Q1). Never required.

Info.plist keys: `NSLocationWhenInUseUsageDescription`, `NSLocationTemporaryUsageDescriptionDictionary`, `UIBackgroundModes = location` (for the background activity session), and `NSLocationAlwaysAndWhenInUseUsageDescription` only if Q1 = yes.

---

## 3. On-device membership engine

All membership decisions happen on the device. Raw `CLLocation` values are kept in memory only, never written to disk, logs, analytics or the network.

### 3.1 Space geometry

Implemented in `Crushly/Location/Geometry.swift`, `MembershipEngine.swift`, `LocationService.swift` (Phase 3).

- Each space is a GeoJSON **Polygon or MultiPolygon** (one zone can be several abutting venues). Membership is tested
  against the union of its polygons, by sampling 64 points on the accuracy circle and 64 at half radius, so the seam
  between two abutting polygons of the same zone is not a boundary.
- Membership test: a fix counts as **inside** only if its whole accuracy circle is inside the polygon, i.e. distance from the point to the nearest edge ≥ `horizontalAccuracy` + `safety_margin_m` (default 5 m). This is conservative by design: the edges of a space are dead zones.
- **Outside** means the accuracy circle is entirely outside the polygon.
- Anything else (straddling the edge, or matching more than one space) is **uncertain**. The engine never picks a space arbitrarily.

### 3.2 States

```
outside ─(coarse trigger or foreground check)→ checking
checking ─(2 qualifying fixes ≥ 5 s apart within 45 s)→ detected(space, visit_id)     ← entry stability
detected ─("Open to matching")→ participating(space, visit_id, session_id)
detected ─("Stay invisible" | dismiss | ignore)→ declined(space, visit_id)            ← no re-prompt this visit
participating ─(uncertain / no fresh evidence)→ paused_unverified                    ← stop renewing; lease lapses ≤ 60 s
paused_unverified ─(qualifying fix before lease expiry)→ participating
paused_unverified ─(lease expired)→ detected (needs fresh confirmation)
any in-space state ─(confident exit: 1 fix fully outside, or 2 consecutive outside-leaning fixes)→ outside   ← immediate revoke
participating(A) ─(qualifying fixes for B)→ revoke A, then detected(B, new visit_id)  ← consent never transfers
any ─(global pause | permission revoked | sign-out)→ revoke + outside/paused
```

- `visit_id` is generated on the device at `detected`. It ends when the user confidently leaves the space. Declines are remembered **only on the device** and only for that `visit_id`. The server never learns that someone declined.
- Visible consent is **never persisted** as a preference. On launch, the state always starts at `outside`/`checking`, and an old session is never resumed silently.

### 3.3 Freshness and accuracy thresholds (initial values; all server-configurable in `app_settings`)

| Threshold | Value | Rationale |
|---|---|---|
| Max horizontal accuracy for evidence | 30 m | Typical outdoor GPS is 5 to 15 m. 30 m rejects Wi-Fi/cell-only and indoor fixes. |
| Max fix age when sent | 15 s | A fix older than one renewal interval is not "fresh". |
| Entry stability | 2 qualifying fixes ≥ 5 s apart within 45 s | Suppresses single jittery fixes. |
| Renewal interval | every 20 s while evidence is fresh | Three attempts per 60 s lease, which tolerates a dropped request. |
| Server lease | 60 s, hard cap | Required by the spec. Server-enforced. |
| Stationary rule | If Core Location reports `stationary` and the last qualifying fix was at least 2× the margin inside the polygon, renewals may cite that fix for up to **5 min**, after which a new fix is required (one-shot request with a 15 s timeout) | Without this, people standing still disappear every minute. The cap limits how long a stale fix can be reused. |

The server cannot verify any of this. It checks that the claims are plausible (accuracy ≤ max, fix age ≤ max, fix timestamps strictly increasing per session, sequence numbers strictly increasing). A heartbeat with no new evidence is rejected (`stale_evidence`). **Device-reported membership is spoofable** (jailbreak, location-spoofing tools, simulator). That limitation is documented, not hidden.

### 3.4 Background, termination and network

- **App backgrounded while participating:** with a `CLBackgroundActivitySession` (blue indicator, started when the user opted in) renewals continue. If iOS stops delivering updates, renewals stop and the lease lapses within 60 s. We never keep someone discoverable because the app went quiet.
- **App terminated / device restarted:** the lease expires on the server within 60 s. On next launch, the engine starts at `checking` and the user is asked again if they're in a space.
- **Foregrounding:** reconcile first (fetch my session state from the server and get a fresh fix), then show candidates. Candidate lists are never shown from cache.
- **Network loss:** renewals fail and the lease lapses. The UI shows "Matching paused, reconnecting". Revocations that fail to send are retried with backoff. The 60 s lease is the backstop.
- **Delayed location events:** fixes with timestamps older than the last one used are discarded.

---

## 4. Server participation model

### 4.1 Tables (replacing `pulse_sessions`, `space_codes`, `encounters`)

```
campus_spaces          id uuid, slug text unique (stable id, e.g. 'usc-village-commons'), name, subtitle,
                       boundary jsonb (GeoJSON polygon), boundary_version int, source_refs jsonb,
                       validation_status ('draft','field_validated'), enabled bool, sort_order
participation_state    user_id pk, consent_epoch bigint not null default 0, matching_paused bool,
                       paused_until timestamptz
participation_sessions id uuid, user_id unique, space_id, boundary_version, consent_epoch,
                       started_at, lease_expires_at, last_seq int, last_fix_at timestamptz, interests_sent int
```

- **At most one row per user** in `participation_sessions` (unique on `user_id`). Rows are **deleted** when a session ends (revoke, expiry, exit). There's no ended/history state, so there's no movement trail.
- `campus_spaces` is readable by authenticated users (the static list plus boundaries the device needs). Spaces can be disabled or have their boundaries changed in the table without an app release. The app ships a bundled copy as an offline fallback, and the server copy wins.
- Server setting `allow_draft_spaces` (default **false**): with it off, sessions can only be opened in `field_validated` spaces. Dev/staging can turn it on.

### 4.2 RPCs (all `security definer`, caller = `auth.uid()`)

| RPC | Effect |
|---|---|
| `my_participation()` | Returns my session (if its lease hasn't expired), `consent_epoch`, pause state and server time. Used for reconciliation. |
| `open_participation(space_slug, boundary_version, consent_epoch, client_request_id, evidence)` | Single transaction: lock my `participation_state` row; reject if paused, epoch ≠ current, space not enabled/validated, boundary_version stale, or evidence fails checks; delete any existing session (plus its interests); insert a new session with `lease = now() + 60 s`. Idempotent on `client_request_id`. |
| `renew_participation(session_id, seq, evidence)` | Requires the session to exist with an unexpired lease, `seq > last_seq`, and fix time > `last_fix_at`. Sets `lease = now() + 60 s` (never beyond). An expired or deleted session can't be renewed (`session_expired`). |
| `revoke_participation(reason)` | Deletes my session and its interests, and increments `consent_epoch`. Idempotent. |
| `set_matching_paused(paused, until)` | Pause: revoke, then set the flag. Resume: clear the flag only. Never opens a session. |

**Out-of-order protection:** every revoke (go invisible, exit, pause, sign-out, account deletion) increments `consent_epoch`. A consent request carries the epoch the device saw when the user tapped "Open to matching". So a delayed or replayed "visible" request carrying an old epoch is rejected (`consent_stale`), and a renewal can't revive a deleted session. All comparisons use server `now()`, and transitions take a row lock on `participation_state`.

**Expiry without cron:** every read path checks `lease_expires_at > now()`, so an expired session is invisible even if cleanup hasn't run. `crushly_tick()` deletes expired rows and their interests every minute, and opportunistic cleanup runs inside the RPCs.

---

## 5. Discovery, interest and matching

### 5.1 Eligibility (one SQL predicate used at all three checkpoints)

`can_match(a, b)` is true only when all of these hold:
- Both are authenticated, have complete profiles, accepted terms, and are 18+.
- Both have unexpired sessions in the same space and the same `boundary_version`.
- Neither is paused.
- No block exists in either direction.
- Each meets the other's preferences (gender/age, §9 Q3) and verified-only setting.

It is checked in `discover_candidates`, `express_interest` and the match transaction.

### 5.2 `discover_candidates(session_id)`

- Requires the caller's own active session (no lurking while invisible).
- **Low-population safeguard:** if fewer than `min_participants` (default **4**, counting the caller) have active sessions in the space, it returns `{status: 'quiet', profiles: []}`. Exact counts are never returned. Tradeoff: a higher value makes it harder to work out who is there, but quiet spaces then show nothing. 4 is a starting point and can be tuned per space.
- Returns at most **8** profiles, in random order on every call (`order by random()`). There's no stable order or cursor to diff between calls.
- Rate limit: 1 call per 15 s and 60 per hour per user, enforced in SQL via a small `rate_limits` counter table (§7.4).
- The returned `public_profile` has **no** space, timestamps, session ids or status.

**Discovery exposures (added in Phase 2):** each discovery call records which sessions were shown to the
caller. `express_interest` only works toward someone actually shown during the current visit. Without this, anyone
who knows a user id (from an old match, for example) could probe it to learn whether that person is in the same space
right now, which would bypass sampling, rate limits and the low-population safeguard. Exposures reference sessions and
cascade away with them.

### 5.3 Interests (anonymous, replacing `heart_signals`)

```
interests  id, sender_session_id → participation_sessions (on delete cascade),
           recipient_session_id → participation_sessions (on delete cascade), created_at
```

- Interests are tied to sessions, not people or places. When either session ends, Postgres cascades the delete: the interest is gone, with nothing to reveal later.
- 5 interests per session (existing rule). One pending interest per sender/recipient pair.
- In-app anonymous receipt: "Someone here is interested", shown only while both sessions are live, after a random delay of 30 to 90 s. There's no push notification for receipts, no time and no place.

### 5.4 Match creation (atomic, idempotent)

In `express_interest`, under a pair advisory lock (the existing pattern): re-check `can_match`. If a reciprocal live interest exists, insert `matches(user_a < user_b)` with `on conflict do nothing` on the **active** pair, delete both interests, and enqueue a generic "You have a new match" notification. The match row stores only the two users and `created_at`. There's no space and no kind. A pair can match again only after the old match was deleted (§6.4).

---

## 6. Chat (no E2EE in this version)

### 6.1 Data

```
matches   id, user_a, user_b, created_at                (unique active pair)
messages  id (client-generated uuid = idempotency key), match_id → matches on delete cascade,
          sender_id, body text (1–2000 chars), payload_version smallint default 1, created_at (server)
```

`payload_version` lets a future E2EE version store ciphertext without a schema migration.

### 6.2 RPCs

- `my_conversations()`: active matches plus the other person's public profile, last message preview and an unread flag.
- `fetch_messages(match_id, before, limit ≤ 50)`: keyset pagination. The caller must be a participant in an active match.
- `send_message(match_id, client_message_id, body)`: participant check, block check, rate limit (e.g. 20/min, 500/day). Idempotent: a retry with the same id returns the existing row, so there are no duplicates. A send to a deleted match returns `not_found` and can't recreate it. The sender is always `auth.uid()`, never a parameter.

There are no direct table grants on `messages` or `matches`. RLS denies everything, and access goes through RPCs only.

### 6.3 Realtime and revocation

- Each user joins one **private Broadcast channel** `user:<uid>`, authorized by an RLS policy on `realtime.messages` (topic must equal the caller's own id).
- The server broadcasts **content-free pokes** only: `{type: 'message' | 'match' | 'conversation_removed', match_id}`. The client then fetches through the RPC, which re-checks authorization on every call.
- Result: even if a connected socket outlives an unmatch or block, it can only learn that "something changed", never message text. Revocation is enforced at the RPC, not by trusting channel teardown. Exact Supabase Realtime authorization caching behavior will be verified against current docs in Phase 5 and covered by tests.

### 6.4 Leave & delete, block, report

- **Leave & delete conversation:** confirm, then `leave_conversation(match_id)` deletes the match (messages cascade), cancels queued outbox rows for that match, and broadcasts `conversation_removed` to both users. Clients purge the cached thread and pending sends. On every launch and reconnect, the client fetches `my_conversations()` before showing any cached thread and purges anything missing.
- **Block:** deletes any match with that person (same purge path) plus both users' live interests. Blocks prevent discovery, interests and messaging until unblocked. Unblocking doesn't restore anything.
- **Report:** the reporter selects specific messages as evidence *before* leaving. `report_user(target, category, details, evidence_message_ids)` copies only those messages into `report_evidence`, which only the service role can access and which is kept for **90 days** (configurable), then purged. Reporting blocks the user by default. Moderators get only what the reporter chose to submit.

### 6.5 Device caches

- Message cache: a file under Application Support with `NSFileProtectionComplete`, excluded from iCloud/iTunes backup (`isExcludedFromBackup`). Deleted on sign-out, account deletion, leave/delete, and block.
- App-switcher privacy cover when the scene goes inactive.
- The auth session is already in the Keychain via supabase-swift. I'll confirm the accessibility class is `afterFirstUnlockThisDeviceOnly`.

---

## 7. Cross-cutting protections

### 7.1 What other users can never see

Another user's space, current or past; distance or direction; arrival or departure; online/last-seen status; exact counts; the place or time of a match; expired interests.

### 7.2 What the server keeps

| Data | Retention |
|---|---|
| Participation session | Only while the lease is valid (≤ 60 s after the last renewal); deleted, not archived |
| Interests | Deleted when either session ends |
| Matches + messages | Until leave & delete, block, or account deletion; then hard-deleted from active storage |
| Report evidence | 90 days, service role only |
| Supabase backups | Platform backups (daily, retention per plan, typically 7 days) may still hold deleted rows until they age out. Documented, not hidden. |
| Analytics | Allow-listed event names only (existing). Space, coordinates and message events removed from the allow-list. |

**Restores:** if the database is restored from backup, all participation sessions are wiped (they'd be expired anyway), and a restore runbook re-applies deletions logged in a minimal `deletion_tombstones(match_id, deleted_at)` table that expires after the backup window. It holds ids only, no participants or content.

### 7.3 Notifications

Lock-screen copy is generic: "You have a new message." / "You have a new match." No sender, text or place. The anonymous-signal push and the Pulse/Find notifications are removed. The optional arrival prompt (Q1) is a *local* notification reading "Open Crushly to choose whether to match here", with no space name on the lock screen.

### 7.4 Rate limits

`rate_limits(user_id, bucket, window_start, count)` with a `hit_rate_limit(bucket, max, window)` helper used by discovery, interests, messages, reports and participation opens. Auth (OTP send/verify) limits come from Supabase Auth config (`config.toml`/dashboard), not SQL.

### 7.5 Logging

No coordinates, space ids, message bodies, tokens or keys in `os_log`, crash reports, analytics or push payloads. Location code uses `privacy: .private` for anything it does log. A unit test greps the source for `print(`/`Logger` calls inside the location module.

### 7.6 Wording guardrails

The app says: "Crushly privately checks whether you're in a campus space. Your precise location is never shown to anyone." It also says plainly that people matching in the same space can infer they're in the same general area. It never claims to be location-free, anonymous, end-to-end encrypted, or endorsed by USC.

---

## 8. Spaces (USC)

### 8.1 What official sources confirm

All six candidates are official Trojan Event Services outdoor venues (trojanevents.usc.edu/venues/outdoor-venues/), each with an official diagram. **No official source we could read publishes coordinates, dimensions or capacity.** maps.usc.edu is a JavaScript map that couldn't be read automatically.

| Candidate | Official name(s) | Neighbors per diagrams | Notes |
|---|---|---|---|
| McCarthy Quad | "McCarthy Quad / Fred Flaggs BBQ" | Doheny & Leavey Libraries, VKC | Page notes proximity to student housing |
| Alumni Park | "Alumni Park" | Trousdale Pkwy, Childs Way, Doheny, Bovard; **Hahn Plaza at its corner** | |
| Hahn Plaza / Tommy Trojan | "Tommy Trojan / Hahn Plaza" | Bovard Administration, Student Union | Abuts Alumni Park |
| Founders Park | "Founders Park" | Taper Hall, Bovard Administration, E.F. Hutton Park, Trousdale | Next to the Hahn/Alumni cluster |
| USC Village Piazza | "University Village (UV) Piazza" / "Village Plaza" / "Central Plaza" | McCarthy Honors (residential college) and other residential colleges | Borders residence halls; polygon must stop at the building line |
| Great Lawn at USC Village | "Great Lawn – UV Space" / "Great Lawn at USC Village" | W 30th St, building 349 (likely a residential college) | About one building away from the Piazza |

### 8.2 Proposed zones

GPS error (10 to 50 m) can't reliably separate abutting venues, so we use three broader zones, each clearly named:

| Zone slug | Display name | Includes |
|---|---|---|
| `upc-center-parks` | Alumni Park & Tommy Trojan | Alumni Park, Hahn Plaza / Tommy Trojan, Founders Park |
| `upc-mccarthy-quad` | McCarthy Quad | McCarthy Quad (open lawn only) |
| `usc-village-commons` | USC Village Piazza & Great Lawn | Village Piazza, Great Lawn |

Polygons exclude building footprints, residential college entrances and courtyards. They're drawn inward from building lines with a buffer and keep a gap of at least 30 m between zones, so a fix can't qualify for two zones at once. Engemann Student Health Center (W 34th St) doesn't border any candidate. Counseling locations will be checked when polygons are drawn.

### 8.2a What Phase 3 actually shipped (all `draft`)

Outlines come from **OpenStreetMap** (ODbL, © OpenStreetMap contributors; way ids recorded in `source_refs`), retrieved
2026-11-16 and cross-checked against the TES venue pages. Bundled in `Crushly/Resources/campus_spaces.json` and seeded
by `supabase/migrations/20261117000000_draft_usc_spaces.sql` (generated from the same file).

| Slug | Name | Contents | Notes |
|---|---|---|---|
| `upc-alumni-park-tommy-trojan` | Alumni Park & Tommy Trojan | Alumni Park (OSM way 154906676) + Hahn Plaza (442277347), MultiPolygon | The two outlines touch (0 m gap). The Tommy Trojan statue falls inside the Hahn Plaza outline |
| `upc-mccarthy-quad` | McCarthy Quad | OSM way 154906727 (~78 × 93 m) | 41 m from the Alumni Park outline |
| `usc-village-great-lawn` | Great Lawn at USC Village | OSM way 727000078 (~97 × 117 m) | |

Left out, and why:
- **Founders Park.** OSM tags E.F. Hutton Park with `old_name = Founders Park`, but USC lists Founders Park and E.F. Hutton Park
  as distinct, adjacent venues. The sources conflict, so it stays out until it's traced from the official diagram.
- **USC Village Piazza.** Not mapped by name in OSM, and it borders residential colleges. It needs tracing from the official
  "Village Plaza" diagram, with the polygon stopping short of the building entrances.

Zone names describe what is actually inside them. The broader names in §8.2 ("…Piazza & Great Lawn") are used only
once those venues are added.

Simulator routes over these drafts are in `Config/Locations/*.gpx`, and `CrushlyTests/GPXReplayTests` replays them
through the engine. Use them via Scheme → Run → Options → Default Location, the Debug bar's location menu, or
`xcrun simctl location booted start --speed=1.4 <lat,lon> <lat,lon> …`.

### 8.3 How boundaries get made (honest version)

1. Trace each polygon over satellite imagery using the official TES diagrams as the reference for what's in and out. Record the source URLs in `source_refs`.
2. Save as `validation_status = 'draft'`, `enabled = true` for dev/staging only. **Drafts can't be used in production** (`allow_draft_spaces = false`).
3. Field validation: walk each perimeter and the middle with a dev build that logs (locally, on-screen only) inside/outside/uncertain verdicts and accuracy. Adjust, bump `boundary_version`, then mark `field_validated`.

Coordinates are not invented here. Drafts are labeled drafts in the data, the docs and the dev UI.

### 8.4 E2EE deferral note

Messages are protected in transit (TLS) and at rest (Supabase storage encryption), and access is restricted by server authorization. **The service operator can technically read messages.** The privacy screen says so. `payload_version` and the content-free realtime design leave room to add a vetted protocol later.

---

## 9. Decisions (answered 2026-11-16)

1. **Arrival detection:** only while the app is open. Once the user opts in, renewal continues in the background with a `CLBackgroundActivitySession` (blue indicator). **When-In-Use only.** No Always permission, no arrival notifications, no `NSLocationAlwaysAndWhenInUseUsageDescription`.
2. **Old connection features:** remove the 24 h confirm/expiry, Connect Later actions, Instagram exchange and Find Each Other. A match is a conversation until leave & delete, block, or account deletion.
3. **Matching preferences:** add "Show me" (women / men / nonbinary people / everyone) plus an age range, enforced in both directions inside `can_match`.
4. **Live data:** the live project has no real users, so the migration is a clean drop-and-replace of the conflicting tables.

## 10. Updated phase plan

| Phase | Scope | Est. |
|---|---|---|
| 2 | Migration: spaces, participation, interests, matches/messages tables, predicates, RPCs, rate limits, RLS; delete conflicting tables; SQL tests for every privacy rule in §5 | 2–3 h |
| 3 | `LocationService` (liveUpdates, CLMonitor trigger, background session, permissions), membership engine + state machine with unit tests, GPX fixtures, draft zone polygons | 2–3 h |
| 4 | Participation, discovery, interests and matching in AppState, Demo + Live backends; consent sheet; remove radar/Around | 2–3 h |
| 5 | Chat, realtime pokes, push copy, leave & delete, block, report evidence, local cache protection | 2–3 h |
| 6 | Spaces / Connections / Me UI, privacy settings, app-switcher cover, accessibility, test rewrite, full run, final report | 2–3 h |
