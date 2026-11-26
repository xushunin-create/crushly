# Moderation and Data Retention

Crushly has no in-app admin console yet. Moderation runs from the Supabase dashboard (SQL Editor or Table Editor), which uses the service role and bypasses RLS. **Only named moderators should have dashboard access.** Assigning that owner is a launch dependency.

## Reports

Reports are written only by the `report_user` RPC. Reporters can't read them back, and reported users can never see them. Filing a report also blocks the reported user for the reporter.

Categories: harassment, fake_profile, under_18, unsafe_behavior, hate_speech, spam, other.

```sql
-- Open queue, oldest first
select r.id, r.created_at, r.category, r.details, r.context,
       r.reported_id, p.first_name, p.photo_review_status,
       (select count(*) from reports x where x.reported_id = r.reported_id) as total_reports_about_user
  from reports r
  left join profiles p on p.id = r.reported_id
 where r.status in ('open', 'reviewing')
 order by r.created_at;

-- Record a decision
update reports
   set status = 'actioned',            -- or 'dismissed' / 'reviewing'
       reviewed_at = now(),
       reviewer_note = 'Removed photos; warned user.'
 where id = '<report id>';
```

**Suggested handling.** Treat `under_18` and `unsafe_behavior` as urgent (same day). Reject photos or delete the account where warranted. Escalate credible threats to USC Department of Public Safety or law enforcement following USC policy.

## Photos and removal

Photos go live as soon as they're saved; there is no review queue. Before upload, the app checks each photo on the
phone for nudity/explicit content (`PhotoSafetyCheck`, a bundled Core ML model) and refuses explicit ones. That check
runs on the device, so a tampered app could skip it: reports are the backstop.

Status is derived when photos change: any photo listed in `photo_flags` → `rejected` (photos hidden from everyone
else, can't match); otherwise at least one photo → `approved`; no photos → `pending`. Clients can't read or change
`photo_flags` or the status, and a flagged photo can't be re-added (`photo_removed`).

To take a photo down after a report:

```sql
update profiles set photo_review_status = 'rejected' where id = '<user id>';
insert into photo_flags (path, user_id, reason) values ('<user id>/<file>.jpg', '<user id>', 'report <report id>');
```

Look at the images in Storage → `profile-photos/<user id>/` (and delete the object if it's illegal content). The user
has to replace the photo to match again.

## Removing a user

As a moderator, delete the user from Authentication → Users (or `auth.admin.deleteUser`). Remove their storage folder first.

## Account deletion (user-initiated)

The `delete-account` edge function verifies the caller, deletes `profile-photos/<uid>/*`, then deletes the auth user. Database foreign keys cascade to every user-owned table.

**Retained after deletion (legitimate moderation interest):**

| Data | What is kept | Why |
|---|---|---|
| Reports the user filed | Row kept, `reporter_id` set to null | Pattern detection about the reported user |
| Reports about the user | Row kept, `reported_id` set to null. `reported_snapshot` holds the reported profile as it was when the report was filed, plus the account's email and deletion time (photos themselves are deleted) | Evidence for repeat-offender review, including a returning email address |

Nothing else is retained. The retention period for reports must be set in the Privacy Policy, e.g. purge reports older than 2 years:

```sql
delete from reports where created_at < now() - interval '2 years' and status in ('actioned', 'dismissed');
```
