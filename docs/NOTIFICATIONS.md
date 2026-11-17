# Notifications and Analytics

## How it works

```
RPCs / crushly_tick ──enqueue──▶ notification_outbox ──claim (every minute)──▶ push-dispatch ──▶ APNs ──▶ iPhone
         (prefs checked)          (dedupe_key unique)    (relevance re-checked)    (discreet copy)
```

1. **Queueing (SQL).** Server functions queue events into `notification_outbox`. Each event has a unique `dedupe_key`, so retries never double-send. Preferences are checked when an event is queued.
2. **Claiming (SQL, service role).** `claim_due_notifications` takes due rows using `SKIP LOCKED`, so parallel runs
   are safe, and re-checks each one at send time (`notification_still_relevant`): the match must still exist, there must
   be no block between the two people, the preference must still be on, the row must be under 6 hours old and under 5
   attempts. Leaving, blocking or deleting a match cancels its queued pushes immediately.
3. **Delivery.** `supabase/functions/push-dispatch` renders the generic copy and sends via APNs. The payload carries
   only `route` (`match:<id>`), never names, text or places. It forgets tokens that Apple reports as dead.
4. **App side** ([Crushly/Services/Notifications/PushManager.swift](../Crushly/Services/Notifications/PushManager.swift)):
   - Permission is asked only after the user taps "Turn on" on a primer shown after their first interest or match.
   - Device tokens are registered after sign-in and unregistered on sign-out.
   - Tapping a notification opens Connections (or that conversation) after sign-in completes. It never grants consent
     or changes visibility.
   - While the app is open, system banners are suppressed; realtime pokes update the UI instead.

## Events and lock-screen copy

| Kind | Trigger | Copy | Preference |
|---|---|---|---|
| `new_match` | A mutual match (both people) | You have a new match. | New matches |
| `new_message` | A message (at most one per conversation per 2 minutes) | You have a new message. | Messages |

There are no presence, arrival, interest or pause notifications: those would reveal where someone is.

## Setup still required (blocked on Apple credentials)

1. **Apple Developer account:**
   - Create an APNs Auth Key (.p8) under Certificates, Identifiers & Profiles → Keys. Note the Key ID and your Team ID.
   - Push Notifications capability: done in the project (`Config/Crushly.entitlements`, `aps-environment`). With automatic signing, Xcode enables Push on the App ID the first time you build to a device; the team must be a paid Apple Developer Program team.
   - Until both are done, iOS refuses remote registration. The app handles that and keeps local reminders working.
2. **Database:** all migrations applied (see [PRE_LAUNCH_CHECKLIST.md](PRE_LAUNCH_CHECKLIST.md) §1).
3. **Deploy the dispatcher.** Go to Edge Functions → Deploy new function → `push-dispatch` → paste the file. **Turn "Verify JWT" off**: the function checks its own shared secret instead. Then add these secrets under Edge Functions → Secrets:

   | Secret | Value |
   |---|---|
   | `APNS_KEY_P8` | Full contents of the .p8 file |
   | `APNS_KEY_ID` | Key ID |
   | `APNS_TEAM_ID` | Team ID of the team that owns `com.iya.crushly` (the app target is signed with `BKR349AF34`; the test targets use a different team) |
   | `APNS_TOPIC` | `com.iya.crushly` |
   | `PUSH_DISPATCH_SECRET` | A long random string |

4. **Run it every minute.** Enable the `pg_cron` and `pg_net` extensions, then run the SQL below. The secret lives in Vault, never in the migration:

   ```sql
   select vault.create_secret('<PUSH_DISPATCH_SECRET>', 'push_dispatch_secret');
   select cron.schedule('crushly-push', '* * * * *', $$
     select net.http_post(
       url := 'https://cgqwbgsnnxioowdtxzls.supabase.co/functions/v1/push-dispatch',
       headers := jsonb_build_object(
         'Content-Type', 'application/json',
         'x-dispatch-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'push_dispatch_secret')),
       body := '{}'::jsonb)
   $$);
   ```

5. **Builds:** Debug builds register as `sandbox`, Release builds as `production`. TestFlight and App Store builds use production APNs.

## Analytics

The `track_event` RPC writes to `analytics_events`, and only names on the server allow-list are accepted. The app sends
no properties. There are deliberately **no participation, space, interest, match or message events**: together they
would form a record of where someone was.

| Event | When |
|---|---|
| `onboarding_completed` | First complete profile and preferences saved |
| `profile_updated` | Profile saved |
| `conversation_left` | Leave & delete |
| `user_blocked` / `user_unblocked` / `user_reported` | Safety actions |
| `notification_prefs_changed` | Notification settings changed |
