# Crushly Backend Contract (Supabase)

The schema, RLS policies and RPCs in `supabase/migrations/` implement this document. The iOS live services (`Crushly/Services/Live/`) call only what is listed here. If you change a signature, update this file, the migration, and the Swift DTO together.

Conventions: `snake_case` everywhere; timestamps are `timestamptz` serialized as ISO-8601; every RPC is `security definer`, `set search_path = public`, granted to `authenticated` only, and resolves the caller via `auth.uid()`. Errors are raised as `raise exception using errcode = 'P0001', message = '<code>'` where `<code>` is one of the error codes in §5, so clients can map them.

## 1. Settings

`app_settings(key text primary key, value jsonb)`, readable by `authenticated`. Seeded keys:

| key | default |
|---|---|
| `allowed_email_domains` | `["usc.edu"]` |
| `pulse_durations_minutes` | `[30, 60]` |
| `signals_per_session` | `5` |
| `signal_validity_hours` | `72` |
| `encounter_window_hours` | `24` |
| `receipt_delay_min_seconds` / `receipt_delay_max_seconds` | `120` / `600` |
| `receipt_time_bucket_minutes` | `15` |
| `receipt_space_min_crowd` | `5` |
| `connection_confirm_hours` | `24` |
| `connection_inactive_days` | `7` |
| `find_request_timeout_minutes` / `find_active_minutes` | `10` / `30` |
| `shield_durations_minutes` | `[60, 240, 1440]` (null = until turned off) |
| `require_own_pulse_to_view_around` | `true` |
| `hide_rejected_photos` | `true` |

Helper: `setting_int(key) returns int`, `setting_json(key) returns jsonb`.

## 2. Tables

Enums: `availability ('meet_now','connect_later','either')`, `intention ('something_serious','something_casual','new_friends','figuring_it_out')`, `review_status ('pending','approved','rejected')`, `selfie_status ('not_started','pending','verified','rejected')`, `space_kind ('place','event')`, `signal_status ('pending','matched','expired','withdrawn')`, `match_kind ('heart_sync','crossed_hearts')`, `connection_status ('pending_confirmation','met_tonight','find_later','expired','removed')`, `connection_action_kind ('coffee','study_break','starter','instagram_exchange')`, `request_status ('pending','accepted','declined','cancelled','timed_out','completed')`, `report_category ('harassment','fake_profile','under_18','unsafe_behavior','hate_speech','spam','other')`, `report_status ('open','reviewing','actioned','dismissed')`.

| Table | Purpose | Client access (RLS) |
|---|---|---|
| `profiles` | Discoverable fields: `id (= auth.users.id)`, `first_name`, `age` (≥18), `pronouns`, `gender`, `interests text[]` (exactly 3), `vibe_tags text[]` (≤5), `prompt_question`, `prompt_answer` (≤160), `intention`, `availability`, `photo_paths text[]` (≤6), `photo_review_status` (server-only), `selfie_status` (server-only), `university_domain` (server-only), `is_complete bool` (generated), `created_at`, `updated_at`. | Owner: select / insert / update except server-only columns (enforced by trigger). Others: no direct select — profiles of others are only returned by RPCs that apply visibility rules. |
| `profile_private` | `user_id`, `instagram_handle`, `age_confirmed_at`, `terms_version`, `terms_accepted_at`, `privacy_version`, `privacy_accepted_at`, `verified_only_discovery bool`. | Owner only. |
| `campus_spaces` | `id`, `name`, `kind`, `subtitle`, `starts_at`, `ends_at`, `is_active`, `sort_order`. | `authenticated` select where `is_active`. |
| `space_codes` | `space_id`, `code` (unique, upper-case). | None (resolved by `enter_space_code`). |
| `pulse_sessions` | `id`, `user_id`, `space_id`, `availability`, `started_at`, `expires_at`, `paused_at`, `ended_at`, `end_reason ('user','expired','shield','account')`, `signals_sent int`. One live (`ended_at is null`) row per user (partial unique index). | Owner select. Writes via RPC only. |
| `encounters` | `viewer_id`, `seen_id`, `space_id`, `last_seen_at`; PK (viewer, seen). Upserted by `around_profiles`. | Viewer select. |
| `heart_signals` | `id`, `sender_id`, `recipient_id`, `session_id`, `space_id`, `created_at`, `expires_at`, `visible_at`, `space_disclosable bool`, `status`, `match_id`. Partial unique (sender, recipient) where status = 'pending'. | **Sender** select own rows. **Recipient: no policy, no grant.** Never in a realtime publication. |
| `matches` | `id`, `user_a < user_b` (unique pair), `kind`, `space_id`, `created_at`. | Participants select. |
| `connections` | `match_id` PK, `status`, `confirm_by`, `active_until`, `confirmed_at`, `last_activity_at`, `removed_by`, `updated_at`. | Participants select. Writes via RPC. |
| `connection_actions` | `id`, `match_id`, `actor_id`, `kind`, `payload jsonb` (e.g. starter id), `status request_status`, `created_at`, `responded_at`. | Participants select. Writes via RPC. |
| `find_requests` | `id`, `match_id`, `requester_id`, `status`, `meeting_point`, `created_at`, `respond_by`, `accepted_at`, `active_until`, `ended_at`, `end_reason`. | Participants select. Writes via RPC. |
| `blocks` | `blocker_id`, `blocked_id`, `created_at`. | Blocker select / delete. Blocked user: nothing. |
| `shield_states` | `user_id` PK, `started_at`, `active_until` (null = indefinite), `ended_at`. | Owner select. Writes via RPC. |
| `reports` | `id`, `reporter_id`, `reported_id`, `category`, `details`, `context jsonb`, `status`, `created_at`, `reviewed_at`, `reviewer_note`. | Reporter: insert via RPC only, no select. Reported user: nothing. Moderators via service role / dashboard. |
| `notification_prefs` | `user_id` PK, `anonymous_signals`, `heart_sync`, `crossed_hearts`, `find_requests`, `connection_reminders`, `connection_expiry`, `pulse_expiry`, `campus_events` (bools, default true), `signals_muted_until`. | Owner select / upsert. |
| `device_tokens` | `user_id`, `token` unique, `platform`, `apns_env ('sandbox','production')`, `updated_at`. | Owner insert / delete / select. |
| `notification_outbox` | `id`, `user_id`, `kind`, `dedupe_key` unique, `payload jsonb`, `deliver_after`, `sent_at`, `cancelled_at`, `attempts`. | None (server only). |
| `analytics_events` | `id`, `user_id`, `name` (checked against allow-list), `props jsonb` (≤1 KB), `created_at`. | Insert via `track_event` only. |

Storage bucket `profile-photos` (private). Path `<user_id>/<uuid>.jpg`. Owner: insert / update / delete within own folder. Read: owner, or any authenticated user for whom `can_view_profile(owner)` is true.

## 3. Visibility predicates (SQL helpers, not granted to clients)

- `is_blocked_between(a, b)` → block exists in either direction.
- `is_shielded(u)` → shield row with `ended_at is null` and (`active_until is null` or `> now()`).
- `live_session(u)` → the user's session with `ended_at is null`, `paused_at is null`, `expires_at > now()`.
- `is_discoverable_to(viewer, target)` → target ≠ viewer, both profiles complete, target has `live_session` in the same space as the viewer's `live_session`, neither shielded, not blocked between, target photo not rejected (when `hide_rejected_photos`), and verified-only filters satisfied on both sides (`verified_only_discovery` means "only show me to, and only show me, people whose `photo_review_status = 'approved'`").
- `can_view_profile(viewer, target)` → discoverable now, OR an encounter within `encounter_window_hours`, OR a match exists — and never if blocked between.

## 4. RPCs

| RPC | Params | Returns | Rules |
|---|---|---|---|
| `my_state()` | – | `jsonb {profile, private, pulse, shield, prefs, settings}` | One call to hydrate the app. `pulse` is the live session (ended_at null) with server `now`. |
| `upsert_profile(p jsonb)` | discoverable fields | `profiles` row | Validates lengths / counts; ignores server-only fields. |
| `accept_terms(terms_version text, privacy_version text, age_confirmed bool)` | | void | `age_confirmed` must be true. |
| `start_pulse(space_id uuid, duration_minutes int, until_event_end bool, availability availability)` | | session row | Requires complete profile, accepted terms, not shielded, no live session (ends any paused/stale one). Duration ∈ `pulse_durations_minutes`, or event end (space must have a future `ends_at`). |
| `pause_pulse()` / `resume_pulse()` / `end_pulse()` | | session row / void | Resume fails with `session_expired` if `expires_at <= now()`. Pause does not extend expiry. |
| `enter_space_code(code text)` | | `campus_spaces` row | Case-insensitive; `invalid_code` if unknown or inactive. |
| `around_profiles()` | | setof `public_profile` (§4.1) | Caller must have a live session (when `require_own_pulse_to_view_around`). Returns targets where `is_discoverable_to(caller, target)`. Upserts encounters. Order by stable hash of `(caller session id, target id)`. |
| `recent_encounters()` | | setof `public_profile` | Encounters within window that are not currently discoverable and still pass `can_view_profile`. |
| `send_heart_signal(recipient uuid)` | | `jsonb {result: 'sent'|'matched', match_id, remaining}` | See §4.2. |
| `my_signal_receipts()` | | setof `{id, received_bucket timestamptz, space_name text|null}` | Recipient view: pending, `visible_at <= now()`, not expired, sender not blocked by/blocking caller, caller not shielded at send. **No sender id, no exact time, no session, no distance.** `space_name` only if `space_disclosable`. |
| `my_sent_signals()` | | setof `{id, recipient public_profile, created_at, expires_at, status}` | |
| `my_matches()` | | setof `{match_id, kind, created_at, space_name, other public_profile, connection connections-row, open_find find_requests-row|null, actions connection_actions[]}` | Blocked pairs excluded. |
| `set_connection_status(match_id, status)` | `met_tonight`/`find_later`/`removed` | connection row | Confirms if pending; sets `active_until = now + inactive_days`. |
| `send_connection_action(match_id, kind, payload)` / `respond_connection_action(action_id, accept bool)` | | action row | One pending action per kind per match. Counts as activity. |
| `connection_instagram(match_id)` | | `text|null` | Other user's handle only if an `instagram_exchange` action in that match is `accepted`. |
| `request_find(match_id, meeting_point text)` / `respond_find(request_id, accept bool)` / `cancel_find(request_id)` / `complete_find(request_id)` | | find row | Both must have live sessions, neither shielded, not blocked. Accept sets `active_until`. Ends automatically if either ends Pulse, enters Shield, or blocks. |
| `enter_shield(duration_minutes int|null)` / `exit_shield()` | | shield row / void | Enter: ends live session (`end_reason='shield'`), cancels open find requests, no notifications to others. Exit never starts Pulse. |
| `block_user(target uuid)` / `unblock_user(target uuid)` / `my_blocks()` | | void / setof `{user_id, first_name, created_at}` | Block also cancels open find requests and withdraws pending signals in both directions. |
| `report_user(target uuid, category report_category, details text, context jsonb)` | | `uuid` | Also blocks the target (default on). |
| `update_notification_prefs(p jsonb)` / `register_device(token, platform, apns_env)` / `unregister_device(token)` | | | |
| `track_event(name text, props jsonb)` | | void | Allow-listed names only. |
| `server_now()` | | `timestamptz` | For clock-skew correction. |

### 4.1 `public_profile` composite

`id, first_name, age, pronouns, gender, interests, vibe_tags, prompt_question, prompt_answer, intention, availability, photo_paths, photo_review_status, space_id, space_name, session_paused bool`. Never includes email, domain beyond `university_domain`, private fields, coordinates, session ids, or timestamps of activity.

### 4.2 `send_heart_signal` algorithm (single transaction)

1. `caller := auth.uid()`; reject `self_signal`.
2. `pg_advisory_xact_lock(hashtextextended(least(caller,recipient)::text || greatest(caller,recipient)::text, 0))` — serializes concurrent sends between the same pair.
3. Caller has `live_session` (`no_live_session`), complete profile, not shielded (`shielded`); recipient not shielded (`not_available`, same message as not discoverable to avoid leaking shield state); not blocked between (`not_available`).
4. Recipient is `is_discoverable_to(caller, recipient)` or an encounter within window (`not_available`).
5. Session `signals_sent < signals_per_session` (`limit_reached`).
6. No pending, unexpired signal caller → recipient (`already_signaled`); no existing match for the pair (`already_matched`).
7. Insert signal (`visible_at = now() + random delay`, `expires_at = now() + validity`, `space_disclosable = live crowd in space ≥ min_crowd`), increment `signals_sent`.
8. If a pending, unexpired signal recipient → caller exists: insert match (`on conflict do nothing` on the pair), kind = heart_sync if both have `live_session` in the same space else crossed_hearts; create `connections` row (`confirm_by = now + confirm_hours`); mark both signals `matched` with `match_id`; enqueue discreet notifications for both. Return `matched`.
9. Otherwise enqueue the recipient's anonymous-signal notification at `visible_at` (respecting prefs / mute). Return `sent`.

## 5. Error codes

`not_authenticated`, `profile_incomplete`, `terms_required`, `domain_not_allowed`, `no_live_session`, `session_expired`, `shielded`, `not_available`, `self_signal`, `limit_reached`, `already_signaled`, `already_matched`, `invalid_duration`, `invalid_code`, `invalid_input`, `not_found`, `not_permitted`, `request_expired`.

## 6. Scheduled maintenance

`crushly_tick()` (pg_cron every minute): end expired sessions (`end_reason='expired'`), expire signals past `expires_at`, expire / remind connections, time out find requests, end expired shields, and enqueue reminders with dedupe keys. Read paths never depend on the tick — they compare timestamps directly — so a missed tick never exposes anyone.

## 7. Edge functions (service role, server-side only)

- `delete-account` — verifies the caller's JWT, deletes `profile-photos/<uid>/*`, then `auth.admin.deleteUser(uid)`; FK cascades remove dependent rows. Reports filed *by* the user are kept with `reporter_id` nulled; reports *about* the user are kept with `reported_id` nulled and a `reported_snapshot` for moderation (documented retention).
- `push-dispatch` — drains `notification_outbox` (due, not sent, not cancelled), re-checks prefs / blocks / staleness, sends via APNs. Lock-screen copy is generic (e.g. "Someone nearby felt a spark.").
