# Crushly Backend Contract (Supabase)

Implemented by `supabase/migrations/` (the current model is `20261116000000_campus_spaces.sql`, built on the two
earlier migrations). Design rationale: [CAMPUS_SPACES_DESIGN.md](CAMPUS_SPACES_DESIGN.md). If you change a signature,
update this file, the migration, the SQL tests and the Swift DTOs together.

Conventions: `snake_case`; timestamps are `timestamptz` (ISO-8601). Every RPC is `security definer`,
`search_path = public`, executable by `authenticated` only, and resolves the caller with `auth.uid()`. Errors are
raised as `P0001` with the message set to an error code from §6.

> **Status (2026-11-16):** the SQL is implemented and tested (`supabase/tests/run.sh`). The iOS live service
> (`Crushly/Services/Live`) still calls the old Pulse RPCs until Phase 4, so **live mode is broken until then**.
> Demo mode is unaffected.

## 1. Settings (`app_settings`, readable by `authenticated`)

| Key | Default | Meaning |
|---|---|---|
| `allowed_email_domains` | `["usc.edu"]` | Sign-up domain allow-list |
| `participation_lease_seconds` | `60` | Hard cap on a participation lease |
| `evidence_max_accuracy_m` | `30` | Worst acceptable horizontal accuracy |
| `evidence_max_fix_age_seconds` | `15` | Max age of a moving fix when sent |
| `evidence_stationary_max_fix_age_seconds` | `300` | Max age of a re-cited fix while Core Location reports stationary |
| `allow_draft_spaces` | `false` | Dev/staging only: allow `draft` spaces |
| `discovery_min_participants` | `4` | Low-population safeguard (counts the caller) |
| `discovery_max_results` | `8` | Max candidates per discovery call |
| `interests_per_session` | `5` | Interests per visit |
| `receipt_delay_min_seconds` / `_max_` | `30` / `90` | Random delay before an anonymous receipt appears |
| `pause_durations_minutes` | `[60, 240, 1440]` | Offered pause lengths (null = until resumed) |
| `message_max_chars` | `2000` | |
| `report_evidence_retention_days` | `90` | |
| `deletion_tombstone_retention_days` | `14` | Should be at least the database backup retention |
| `rate_limits` | see migration | `bucket -> [[max, window_seconds], ...]` for `open`, `renew`, `discover`, `interest`, `message`, `report` |
| `hide_rejected_photos` | `true` | |
| `analytics_allowed_events` | see migration | No presence, participation, interest or match events |

## 2. Tables and client access

| Table | Purpose | Client access |
|---|---|---|
| `profiles` | Public profile fields (unchanged) | Owner read/write (server-only columns guarded) |
| `profile_private` | Terms/age confirmation, `verified_only_discovery`, matching prefs: `match_gender` (`woman`/`man`/`nonbinary`), `show_me text[]`, `age_min`, `age_max` | Owner read. Prefs written only by `update_match_preferences` |
| `campus_spaces` | `slug` (stable id), `name`, `subtitle`, `boundary` (GeoJSON Polygon), `boundary_version`, `source_refs`, `validation_status` (`draft`/`field_validated`), `enabled`, `sort_order` | Read where `enabled` and (`field_validated` or `allow_draft_spaces`) |
| `participation_state` | `consent_epoch`, `matching_paused`, `paused_until` | None (via RPC) |
| `participation_sessions` | One row per user at most: space, boundary version, epoch, lease, last seq/fix, `interests_sent`. **Deleted when it ends.** | None |
| `discovery_exposures` | (viewer session, target session) pairs that discovery returned. Cascades with sessions | None |
| `interests` | (sender session, recipient session, `visible_at`). Cascades with sessions | None |
| `matches` | `user_a < user_b`, `created_at`, per-side read markers. **No place.** | None |
| `messages` | Client-generated `id`, `match_id`, `sender_id`, `body`, `payload_version` (1; 2+ reserved for E2EE), `created_at` | None |
| `report_evidence` | Messages the reporter selected; `purge_after` | None (service role) |
| `deletion_tombstones` | `match_id`, `deleted_at` only | None (service role) |
| `rate_limits` | Fixed-window counters | None |
| `notification_prefs` | `new_matches`, `messages` | None (via RPC) |
| `blocks`, `reports`, `device_tokens`, `notification_outbox`, `analytics_events` | As before | As before |

Storage bucket `profile-photos` (private). Readers: the owner, a matched user, or a user who `can_match` right now.

## 3. Internal predicates (not executable by clients)

- `can_match(a, b)`: both profiles complete with terms and preferences; unexpired sessions in the same space and
  boundary version; each satisfies the other's `show_me` and age range; photo and verified-only rules; neither
  paused; no block either way.
- `check_evidence(evidence, prev_fix_ts_ms, allow_stationary)`: shape, accuracy, fix age, and monotonic fix time
  (a stationary renewal may re-cite the last fix).
- `end_participation(u)`: deletes the session (interests and exposures cascade) and increments `consent_epoch`.
- `delete_match(id)`: deletes the match (messages cascade), cancels queued pushes, writes a tombstone.

## 4. RPCs

### Account
| RPC | Returns | Notes |
|---|---|---|
| `server_now()` | `timestamptz` | |
| `my_state()` | `jsonb {now, profile, private, prefs, settings}` | |
| `upsert_profile(p jsonb)`, `accept_terms(...)` | | Unchanged |
| `update_match_preferences(p_match_gender, p_show_me text[], p_age_min, p_age_max)` | void | Validated; 18 ≤ min ≤ max ≤ 120 |
| `update_notification_prefs(p jsonb)` | `notification_prefs` | Keys `new_matches`, `messages` |
| `register_device`, `unregister_device`, `track_event` | | Unchanged |

### Participation
Evidence object: `{"fix_ts_ms": <device epoch ms>, "fix_age_ms": <ms>, "horizontal_accuracy_m": <m>, "stationary": <bool>}`.

| RPC | Returns | Rules / errors |
|---|---|---|
| `my_participation()` | `jsonb {now, consent_epoch, matching_paused, paused_until, session: {id, space_slug, boundary_version, lease_expires_at, last_seq} \| null}` | Reconcile with this on launch and foreground |
| `open_participation(p_space_slug, p_boundary_version, p_consent_epoch, p_client_request_id, p_evidence)` | `jsonb {session_id, lease_expires_at, now}` | Idempotent on `p_client_request_id` while valid. Replaces any existing session. Errors: `matching_paused`, `consent_stale`, `profile_incomplete`, `space_unavailable`, `boundary_outdated`, `insufficient_accuracy`, `stale_evidence`, `invalid_input`, `rate_limited` |
| `renew_participation(p_session_id, p_seq, p_evidence)` | `jsonb {session_id, lease_expires_at, now}` | `p_seq` strictly increasing. Errors: `session_expired` (final), `stale_request`, `stale_evidence`, `insufficient_accuracy`, `matching_paused`, `rate_limited` |
| `revoke_participation()` | new `consent_epoch` (`bigint`) | Go invisible / exit / sign-out. Idempotent |
| `set_matching_paused(p_paused, p_minutes default null)` | same as `my_participation()` | Pausing revokes; resuming never opens a session |

### Discovery and interest
| RPC | Returns | Rules / errors |
|---|---|---|
| `discover_candidates()` | `jsonb {status: 'ok' \| 'quiet', profiles: public_profile[]}` | Caller must be participating (`not_participating`). `quiet` when fewer than `discovery_min_participants` (no count is returned). Random order, capped, rate-limited. Records exposures |
| `express_interest(p_target)` | `jsonb {result: 'sent' \| 'matched', match_id, remaining}` | Target must currently `can_match` **and** have been shown to the caller during this visit; otherwise `not_available`. Also `not_participating`, `already_sent`, `already_matched`, `limit_reached`, `invalid_input`, `rate_limited`. Matching is atomic per pair |
| `my_interest_receipts()` | `int` | Visible, live interests toward me this visit. No ids, times or places |
| `my_sent_interests()` | `uuid[]` | Whom I've expressed interest in this visit |

`public_profile` = `id, first_name, age, pronouns, gender, interests, vibe_tags, prompt_question, prompt_answer,
intention, availability, photo_paths, photo_review_status`. It never contains a space, session, status, timestamps or email.

### Conversations
| RPC | Returns | Rules / errors |
|---|---|---|
| `my_conversations()` | rows `{match_id, created_at, other public_profile, last_message_at, last_message_preview, last_message_from_me, unread}` | Source of truth on launch and reconnect: purge any cached conversation not listed |
| `fetch_messages(p_match_id, p_before_created_at, p_before_id, p_limit ≤ 50)` | rows `{id, sender_is_me, body, created_at}`, newest first | Keyset pagination: pass both cursor parts or neither. `not_found` for non-participants or deleted matches |
| `send_message(p_match_id, p_client_message_id, p_body)` | `{id, created_at}` | Retry-safe: same id returns the existing row. A reused id from another sender or match gets `invalid_input`. `not_found` once the match is gone, so a queued send can't recreate it. `rate_limited` |
| `mark_conversation_read(p_match_id)` | void | |
| `leave_conversation(p_match_id)` | void | Ends the match and deletes all messages for both. `not_found` if already gone |

### Safety
| RPC | Returns | Notes |
|---|---|---|
| `block_user(target)` | void | Also deletes any match/conversation and pending interests between the two |
| `unblock_user(target)`, `my_blocks()` | | Unblocking restores nothing |
| `report_user(target, category, details, evidence_message_ids uuid[] default '{}')` | report id | Evidence must be messages from the conversation with `target` (`invalid_input` otherwise). Copied to `report_evidence` (90 days), then the user is blocked, which deletes the conversation |

## 5. Notifications

Kinds: `new_match`, `new_message`. The payload is `{match_id}` only. Lock-screen copy (in `functions/push-dispatch`) is
"You have a new match." / "You have a new message." Message pushes collapse to one per conversation per 2 minutes.
Relevance is re-checked at send time: the match must still exist, there must be no block, and the preference must be on.

## 6. Error codes

`not_authenticated`, `invalid_input`, `not_found`, `rate_limited`, `profile_incomplete`, `matching_paused`,
`consent_stale`, `space_unavailable`, `boundary_outdated`, `insufficient_accuracy`, `stale_evidence`, `stale_request`,
`session_expired`, `not_participating`, `not_available`, `already_sent`, `already_matched`, `limit_reached`,
`invalid_duration`, `domain_not_allowed`.

## 7. Scheduled maintenance

`crushly_tick()` (pg_cron, every minute) deletes expired sessions (interests and exposures cascade), clears
finished timed pauses, purges report evidence and tombstones past retention, and trims old rate-limit and outbox rows.
No read path depends on it.

## 8. Known limitations (stated, not hidden)

- **Location is device-reported.** The server checks plausibility (accuracy, freshness, monotonic fixes, sequence
  numbers), not truth. A spoofed device can claim to be in a space.
- **Inference.** Two matched people know they were in the same space at the same time. A discovery result, or a
  `quiet` status, tells a participant something about who is or isn't in the space right now.
- **Not end-to-end encrypted.** Messages are protected by TLS in transit and by Supabase storage encryption at rest,
  and are reachable only through participant-checked RPCs. The service operator can read them.
- **Backups.** Deleted rows can persist in platform backups until those backups age out. `deletion_tombstones` lets a
  restore re-apply deletions made inside the tombstone window.
