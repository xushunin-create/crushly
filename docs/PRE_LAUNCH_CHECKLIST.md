# Pre-launch checklist

Everything here must be done (and ticked by a named person) before real users. Items are grouped by where they happen.
Design rationale: [CAMPUS_SPACES_DESIGN.md](CAMPUS_SPACES_DESIGN.md). Server contract: [BACKEND_CONTRACT.md](BACKEND_CONTRACT.md).

## 1. Database settings (Supabase SQL Editor)

- [ ] **`allow_draft_spaces` is `false`.** Drafts must never be usable in production:
  ```sql
  update public.app_settings set value = 'false' where key = 'allow_draft_spaces';
  select value from public.app_settings where key = 'allow_draft_spaces';   -- expect false
  ```
- [ ] **`deletion_tombstone_retention_days` ≥ your backup retention** (check Project Settings → Database → Backups; the
  default setting is 14 days):
  ```sql
  update public.app_settings set value = '<days>' where key = 'deletion_tombstone_retention_days';
  ```
- [ ] **pg_cron enabled**, with `crushly_tick()` scheduled every minute (sessions, pauses, evidence and tombstone
  retention), plus the `push-dispatch` schedule from [NOTIFICATIONS.md](NOTIFICATIONS.md). The init migration only
  schedules the tick if pg_cron was already enabled when it ran; check, and schedule it if missing:
  ```sql
  select jobname from cron.job;   -- expect crushly-tick (and crushly-push)
  select cron.schedule('crushly-tick', '* * * * *', 'select public.crushly_tick()');
  ```
  No read path depends on the tick (every check uses `lease_expires_at > now()`), but retention does.
- [ ] All migrations applied in order: `20261110000000_init`, `20261111000000_notifications`,
  `20261116000000_campus_spaces`, `20261117000000_draft_usc_spaces`, `20261118000000_realtime_pokes`.
- [ ] Review the other `app_settings` values (discovery minimum of 4, 8 results, 5 interests per visit, 30–90 s receipt
  delay, rate limits) and tune them for launch.

## 2. Campus spaces (field validation)

All three shipped zones are **drafts** traced from OpenStreetMap outlines. None has been walked.

- [ ] For each zone (`upc-alumni-park-tommy-trojan`, `upc-mccarthy-quad`, `usc-village-great-lawn`): walk the
  perimeter and the middle with a dev build, at different times of day, near building edges and under trees. Record
  inside / outside / uncertain verdicts and the reported accuracy.
  - **Gap:** there is no on-screen field-validation overlay yet (design §8.3 step 3). Build one (DEBUG only, on-screen
    only, never logged) before the walk, or use the GPX routes in `Config/Locations/` to rehearse first.
- [ ] Adjust each polygon, keeping a ≥ 30 m gap between zones and stopping short of building entrances, residence-hall
  courtyards and health/counseling locations.
- [ ] **Bump `boundary_version`** for every changed zone (consent is tied to the version), then set
  `validation_status = 'field_validated'`. Update `Crushly/Resources/campus_spaces.json` (the offline fallback) to
  match, and keep `source_refs` current.
- [ ] **Founders Park** and **USC Village Piazza**: trace from the official Trojan Event Services diagrams (design
  §8.2a explains why they were left out), then walk and validate them like the others before enabling.
- [ ] Keep the "© OpenStreetMap contributors" attribution in the app (Spaces tab) for any OSM-derived outline.

## 3. Dashboard and services

- [ ] **Realtime → Settings: "Allow public access" OFF** (only private channels). *(Done by the owner on 2026-11-16;
  re-check after any project migration.)*
- [ ] **Auth → JWT expiry short** (for example 10–15 minutes). Realtime keeps a channel authorized until the JWT
  expires, so shorter tokens shorten how long a revoked subscriber can keep receiving content-free pokes.
- [ ] **Custom SMTP** configured (Authentication → SMTP) on the owned domain, and the Magic Link template includes
  `{{ .Token }}` (6-digit code).
- [ ] **Remove the dev sign-in bypass** (`devSignIn`, `supabase/dev/create_dev_user.sql`, the dev account) once SMTP works.
- [ ] **APNs:** auth key (.p8), the Push Notifications capability in Xcode, and the `push-dispatch` secrets
  ([NOTIFICATIONS.md](NOTIFICATIONS.md)).
- [ ] **Redeploy edge functions** from the current source: `push-dispatch` (Verify JWT off; copy is now "You have a new
  match." / "You have a new message.") and `delete-account` (Verify JWT on).
- [ ] Supabase Auth rate limits for OTP send/verify reviewed (they are not enforced in SQL).

## 4. App build

- [ ] `Crushly/Resources/Secrets.plist` contains only the project URL and the **anon/publishable** key. Never the
  service-role key.
- [ ] Confirm the auth session's Keychain accessibility class in supabase-swift (design §6.5 asks for
  `afterFirstUnlockThisDeviceOnly`); change the storage if it isn't.
- [ ] Release build runs in live mode (no DEMO badge); the demo fixture and simulated location are unreachable without
  `-CrushlyDemo` or missing secrets.
- [ ] App Store privacy labels: precise location (used on device, not collected or linked), messages (collected,
  linked), photos, email. Review notes: 18+, USC-only, not affiliated with USC.

## 5. Legal and operations

- [ ] Real Terms of Service and Privacy Policy replace the development placeholders (`LegalDocuments.isPlaceholder`).
  The privacy policy must say: location is evaluated on the device; the server receives only a space id with a 60 s
  lease; messages are **not end-to-end encrypted** and the operator can technically read them; report evidence is kept
  90 days; deleted data persists in backups until they age out; people matching in a space can infer co-presence.
- [ ] A named moderation owner and review process ([MODERATION.md](MODERATION.md)), including access to
  `report_evidence` (service role only) and the 90-day purge.
- [ ] Restore runbook: after any database restore, wipe `participation_sessions` and re-apply deletions from
  `deletion_tombstones` (design §7.2).

## 6. Physical-device testing at USC (cannot be done in the simulator)

- [ ] Entry latency (arrival → prompt) and exit latency (leaving → revoke) in each zone.
- [ ] Accuracy near buildings and under tree cover: how often fixes exceed 30 m or straddle edges (uncertain).
- [ ] Standing still: the stationary rule keeps someone visible for up to 5 minutes, then requires a new fix.
- [ ] Background renewal with the blue indicator: app backgrounded, screen locked, Low Power Mode, poor signal.
- [ ] Battery use over a 30–60 minute visit.
- [ ] Approximate-location users: temporary precise access prompt and recovery.
- [ ] Two real accounts: match, chat, realtime pokes, leave & delete, block, report, push copy on the lock screen.
