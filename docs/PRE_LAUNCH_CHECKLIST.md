# Pre-launch checklist

Everything here must be done (and ticked by a named person) before real users. Items are grouped by where they happen.
Design rationale: [CAMPUS_SPACES_DESIGN.md](CAMPUS_SPACES_DESIGN.md). Server contract: [BACKEND_CONTRACT.md](BACKEND_CONTRACT.md).

## 1. Database settings (Supabase SQL Editor)

Run [`supabase/ops/verify_production.sql`](../supabase/ops/verify_production.sql) (read-only) first and again before
launch: it checks most of §1, the dev account, enabled zones and the photo bucket in one table of PASS/FAIL/CHECK rows.

- [x] **`allow_draft_spaces` is `false`.** *(Verified 2026-11-17 by `verify_production.sql`.)* Drafts must never be usable in production:
  ```sql
  update public.app_settings set value = 'false' where key = 'allow_draft_spaces';
  select value from public.app_settings where key = 'allow_draft_spaces';   -- expect false
  ```
- [x] **`deletion_tombstone_retention_days` ≥ your backup retention** (check Project Settings → Database → Backups; the
  default setting is 14 days). *(2026-11-17: the project is on the Free plan, which has no automatic backups, so 14 days
  is enough. **Re-check if you upgrade**: Pro keeps 7 days of daily backups, and point-in-time recovery can keep more.)*
  ```sql
  update public.app_settings set value = '<days>' where key = 'deletion_tombstone_retention_days';
  ```
- [x] **pg_cron enabled** *(verified 2026-11-17: `crushly-tick` and `crushly-push` active)*, with `crushly_tick()` scheduled every minute (sessions, pauses, evidence and tombstone
  retention), plus the `push-dispatch` schedule from [NOTIFICATIONS.md](NOTIFICATIONS.md). The init migration only
  schedules the tick if pg_cron was already enabled when it ran; check, and schedule it if missing:
  ```sql
  select jobname from cron.job;   -- expect crushly-tick (and crushly-push)
  select cron.schedule('crushly-tick', '* * * * *', 'select public.crushly_tick()');
  ```
  No read path depends on the tick (every check uses `lease_expires_at > now()`), but retention does.
- [ ] All migrations applied in order: `20261110000000_init`, `20261111000000_notifications`,
  `20261116000000_campus_spaces`, `20261117000000_draft_usc_spaces`, `20261118000000_realtime_pokes`,
  `20261119000000_discovery_min_two`, `20261120000000_indoor_zones_iyh`. Check with
  `npx supabase db push --remote --dry-run` (expect "up to date"). *(2026-11-17: the first five were applied by hand and
  recorded with `migration repair`; `discovery_min_two` was pushed.)*
- [ ] Review the other `app_settings` values (discovery minimum of 2, 8 results, 5 interests per visit, 30–90 s receipt
  delay, rate limits) and tune them for launch.

## 2. Campus spaces (field validation)

All four shipped zones are **drafts** traced from OpenStreetMap outlines. None has been walked. **Until at least one
zone is `field_validated`, nobody can join a space on the production backend.**

- [ ] For each zone (`upc-alumni-park-tommy-trojan`, `upc-mccarthy-quad`, `usc-village-great-lawn`,
  `upc-iovine-young-hall`): walk the
  perimeter and the middle with a dev build, at different times of day, near building edges and under trees. Record
  inside / outside / uncertain verdicts and the reported accuracy.
  - Use the DEBUG **field-validation overlay** (Spaces tab → "Field validation overlay"): it classifies every fix
    against all enabled zones (drafts included), shows accuracy, fix age, coordinates and distance to each boundary,
    and lets you tap Inside / Edge / Outside to tally ground truth vs verdict. **False INSIDE must be 0.** In-memory
    only; cleared when closed. Rehearse first with the GPX routes in `Config/Locations/`. The dev project needs
    `allow_draft_spaces = true` (or a DEBUG build's bundled drafts) for the engine to use drafts; the overlay itself
    ignores that setting.
- [ ] **Iovine and Young Hall is an indoor zone** (design §3.1a: `point` rule, 40 m accuracy limit). Confirm it is the
  right building (OSM: 3738 Watt Way), then walk every floor and the pavement right outside the walls. False INSIDE
  just outside the walls is the expected weakness of this rule; if it happens often, shrink the outline inward.
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
- [ ] **Auth → JWT expiry short** (900 s, matching `supabase/config.toml`; also turn on refresh-token rotation). Realtime keeps a channel authorized until the JWT
  expires, so shorter tokens shorten how long a revoked subscriber can keep receiving content-free pokes.
- [ ] **Custom SMTP** configured (Authentication → SMTP) on the owned domain, and the Magic Link template includes
  `{{ .Token }}` (6-digit code).
- [x] **Dev sign-in bypass:** removed from the app and `create_dev_user.sql` deleted (2026-11-16). Server-side account
  gone *(verified 2026-11-17 by `verify_production.sql`)*. If it ever comes back, delete it with [`supabase/ops/remove_dev_account.sql`](../supabase/ops/remove_dev_account.sql).
- [x] **APNs:** auth key (.p8), the Push Notifications capability in Xcode, and the `push-dispatch` secrets
  ([NOTIFICATIONS.md](NOTIFICATIONS.md)). *(2026-11-17: key `78K6WANWT7` on team `BKR349AF34`, Sandbox & Production;
  all five secrets set; first dispatch returned 200. Keep the .p8 in a password manager, never in the repo.)*
- [ ] **Push end to end on a real iPhone:** allow notifications, confirm a row in `device_tokens`, get a match, and
  confirm the push arrives (`net._http_response` shows `sent ≥ 1`).
- [x] **Redeploy edge functions** *(2026-11-17: both deployed; until then `delete-account` was missing in production)* from the current source: `push-dispatch` (Verify JWT off; copy is now "You have a new
  match." / "You have a new message.") and `delete-account` (Verify JWT on).
- [ ] **Account deletion end to end:** delete a throwaway account from the app and confirm it is gone.
- [ ] Supabase Auth rate limits for OTP send/verify reviewed (they are not enforced in SQL).

## 4. App build

- [ ] `Crushly/Resources/Secrets.plist` contains only the project URL and the **anon/publishable** key. Never the
  service-role key.
- [x] Auth session Keychain class is `afterFirstUnlockThisDeviceOnly` (design §6.5): supabase-swift's default is
  `afterFirstUnlock`, so `SessionKeychainStorage` replaces it and upgrades existing items on first read (2026-11-16).
- [ ] Release build runs in live mode (no DEMO badge); the demo fixture and simulated location are unreachable without
  `-CrushlyDemo` or missing secrets.
- [x] Privacy manifest `Crushly/Resources/PrivacyInfo.xcprivacy` (2026-11-17): no tracking; `UserDefaults` reason
  `CA92.1`; collected types listed below.
- [x] iPhone only (`TARGETED_DEVICE_FAMILY = 1`), so no iPad screenshots or iPad review. `ITSAppUsesNonExemptEncryption
  = false` in `Config/Crushly-Info.plist` (HTTPS only; revisit if E2EE is added).
- [ ] App Store privacy labels must **match the manifest**. All are "linked to you", none used for tracking, purpose
  App Functionality unless noted: Email Address, Name, User ID, Photos, Emails or Text Messages, Other User Content,
  Sensitive Info (gender / "Show me" can reveal orientation), **Coarse Location** (the campus space you're open to
  matching in; coordinates never leave the phone), Product Interaction (purpose: Analytics). Precise location is used
  only on the device and is not collected. If you decide the space id isn't "location", remove Coarse Location from
  both the manifest and the labels. Review notes: 18+, USC-only, not affiliated with USC.
- [ ] **App Review sign-in.** Reviewers can't receive a USC email code, so one fixed account,
  `crushly-appreview@usc.edu`, signs in with a fixed 6-digit code through the `review-sign-in` edge function (no email
  is sent; the account has no password, so `verify_production.sql` check 7 still passes; 10 tries/hour, 30/day).
  1. Apply `20261121000000_review_sign_in` (adds the `review_sign_in` rate limit).
  2. `supabase secrets set REVIEW_EMAIL=crushly-appreview@usc.edu REVIEW_CODE=<6 random digits>`
  3. `supabase functions deploy review-sign-in --no-verify-jwt`
  4. Sign in once yourself with that email and code, and finish the profile so the reviewer lands in a working app.
  5. App Store Connect → App Review Information: sign-in required, user name `crushly-appreview@usc.edu`, password
     `<the code>`. In Notes, say: type the email, tap *Email me a code*, then enter the code (no email is sent);
     matching only works inside the USC campus spaces, so attach a screen recording of the in-space flow.
  To turn it off later, `supabase secrets unset REVIEW_CODE` (the function then rejects every attempt).

## 5. Legal and operations

- [ ] Real Terms of Service and Privacy Policy. **Drafts** are in `Crushly/Resources/Legal/terms.md` and `privacy.md`:
  replace every `[[FILL-IN]]` (operator name, address, contact email, email provider, governing law, report/analytics/
  backup retention), have a lawyer review, then bump `LegalDocuments.termsVersion`/`privacyVersion`.
  `LegalDocuments.isPlaceholder` (and the in-app "Draft" banner) turns off automatically once no `[[` remains.
  The privacy policy must say: location is evaluated on the device; the server receives only a space id with a 60 s
  lease; messages are **not end-to-end encrypted** and the operator can technically read them; report evidence is kept
  90 days; deleted data persists in backups until they age out; people matching in a space can infer co-presence.
- [ ] A named moderation owner and review process ([MODERATION.md](MODERATION.md)), including access to
  `report_evidence` (service role only) and the 90-day purge.
- [ ] Restore runbook (only matters once the project has backups; the Free plan has none): after any database restore, wipe `participation_sessions` and re-apply deletions from
  `deletion_tombstones` (design §7.2).

## 6. Physical-device testing at USC (cannot be done in the simulator)

- [ ] Entry latency (arrival → prompt) and exit latency (leaving → revoke) in each zone.
- [ ] Accuracy near buildings and under tree cover: how often fixes exceed 30 m or straddle edges (uncertain).
- [ ] Standing still: the stationary rule keeps someone visible for up to 5 minutes, then requires a new fix.
- [ ] Background renewal with the blue indicator: app backgrounded, screen locked, Low Power Mode, poor signal.
- [ ] Battery use over a 30–60 minute visit.
- [ ] Approximate-location users: temporary precise access prompt and recovery.
- [ ] Two real accounts: match, chat, realtime pokes, leave & delete, block, report, push copy on the lock screen.
