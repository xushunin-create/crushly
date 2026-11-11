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

## Photo review

New or changed photos are `pending`. Pending photos are visible but never show a verified badge. `rejected` photos are hidden from everyone else. Only the server or a moderator can change the status; clients can't.

```sql
-- Review queue
select id, first_name, photo_paths, updated_at
  from profiles where photo_review_status = 'pending' order by updated_at;

-- Decide
update profiles set photo_review_status = 'approved' where id = '<user id>';   -- or 'rejected'
```

Look at the images in Storage → `profile-photos/<user id>/`.

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
