# Notifications and Analytics

## How it works

```
RPCs / crushly_tick ──enqueue──▶ notification_outbox ──claim (every minute)──▶ push-dispatch ──▶ APNs ──▶ iPhone
         (prefs checked)          (dedupe_key unique)    (relevance re-checked)    (discreet copy)
```

1. **Queueing (SQL).** Server functions queue events into `notification_outbox`. Each event has a unique `dedupe_key`, so retries never double-send. Preferences are checked when an event is queued.
2. **Claiming (SQL, service role).** `claim_due_notifications` takes due rows using `SKIP LOCKED`, so parallel runs are safe, and re-checks each one at send time:
   - It's cancelled if the user has since blocked the sender, entered Protect My Heart, changed preferences or muted alerts.
   - It's cancelled if the signal matched or expired, or if the meet request was answered.
   - It's cancelled if it's more than 6 hours old or the user has no device.
   - A row is retried at most 5 times.
3. **Delivery.** `supabase/functions/push-dispatch` renders discreet copy and sends via APNs. It forgets tokens that Apple reports as dead.
4. **App side** ([Crushly/Services/Notifications/PushManager.swift](../Crushly/Services/Notifications/PushManager.swift)):
   - Permission is asked only after the user taps "Turn on" on a primer shown after their first Heart Signal.
   - Device tokens are registered after sign-in.
   - Tapping a notification opens the right screen, after sign-in completes if needed.
   - While the app is open, system banners are suppressed: the app's own UI shows what changed.

## Events and lock-screen copy

The copy never contains a name, photo, place or distance, not even for a mutual match.

| Kind | Trigger | Copy | Preference |
|---|---|---|---|
| `anonymous_signal` | Someone signals you (sent after the 2–10 min receipt delay) | Someone nearby felt a spark. | Anonymous Heart Signals, and not muted |
| `heart_sync` | Mutual match, same moment | Someone felt it too. Open Crushly to see. | Heart Sync |
| `crossed_hearts` | Mutual match, later | You missed the moment, not each other. | Crossed Hearts |
| `find_request` | Match asks to meet now | You have a new request. | Meeting requests |
| `find_accepted` | Your meet request was accepted | Your request was accepted. | Meeting requests |
| `connection_action` | Coffee, study break, starter or Instagram request | You have something new waiting. | Connect Later reminders |
| `connection_reminder` | 4 h and 1 h before a connection expires | A connection is waiting on you. | Connect Later reminders |
| `connection_expired` | Connection expired | A saved connection has expired. | Connection expiring |
| `pulse_expiring` | 5 min before your session ends | Your Pulse ends in 5 minutes. | Pulse session ending |
| `campus_event` | Reserved; there's no event source yet | (none) | Campus events |

**Without APNs**, the app schedules the Pulse-ending reminder locally on the device. Once a push token exists, the server version replaces it, so users aren't reminded twice.

## Setup still required (blocked on Apple credentials)

1. **Apple Developer account:**
   - Create an APNs Auth Key (.p8) under Certificates, Identifiers & Profiles → Keys. Note the Key ID and your Team ID.
   - In Xcode, select the Crushly target → Signing & Capabilities → **+ Push Notifications**. This adds the `aps-environment` entitlement.
   - Until both are done, iOS refuses remote registration. The app handles that and keeps local reminders working.
2. **Database:** run `supabase/migrations/20261111000000_notifications.sql` in the SQL Editor (after the init migration).
3. **Deploy the dispatcher.** Go to Edge Functions → Deploy new function → `push-dispatch` → paste the file. **Turn "Verify JWT" off**: the function checks its own shared secret instead. Then add these secrets under Edge Functions → Secrets:

   | Secret | Value |
   |---|---|
   | `APNS_KEY_P8` | Full contents of the .p8 file |
   | `APNS_KEY_ID` | Key ID |
   | `APNS_TEAM_ID` | Team ID (currently `22MPL655RF` in the Xcode project) |
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

The `track_event` RPC writes to `analytics_events`, and only names on the server allow-list are accepted. The app sends no properties: no location, no profile content, no other user's id.

| Event | When |
|---|---|
| `onboarding_completed` | First complete profile saved |
| `pulse_started` | Entered the Radius |
| `signal_sent` | Heart Signal sent |
| `match_viewed` | Mutual match reveal shown |
| `connection_action_sent` | Coffee, study break, starter or Instagram request sent |
| `find_requested` | Asked to meet now |
| `shield_entered` | Protect My Heart turned on |

Example funnel query:

```sql
select name, count(*) as events, count(distinct user_id) as users
  from analytics_events where created_at > now() - interval '7 days'
 group by name order by users desc;
```
