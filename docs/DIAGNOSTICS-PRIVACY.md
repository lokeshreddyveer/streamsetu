# Problem reports: what leaves the device, and what to check on the server

StreamSetu can send a playback log to a small service run by the developer (a Supabase project in London, edge function `submit-log`). This page is the single reference for what is sent, when, and what the server must do. The apps' privacy text, the privacy manifests and the tests are all written against it.

## When it is sent

- **Automatic report:** only if the person said yes when the app first asked, or turned it on in Settings → Send Feedback. It is **off until then**. It happens after a stream fails for good, at most once in three hours.
- **By hand:** "Send My Log Now" in Send Feedback, whatever the setting.
- Never during playback, and never from the Android apps (they do not have this service).

## What is sent

One HTTPS POST to `https://<project>.supabase.co/functions/v1/submit-log`, with `Content-Type: application/json` and no account, key or cookie. The body has exactly these fields (the test `DiagnosticsContractTests` fails if one is added or removed):

| Field | Value |
|---|---|
| `install_id` | A random UUID made on the device the first time it is needed. It only groups one device's reports. |
| `trigger` | `auto` or `manual` |
| `platform` | The platform name (macOS or iOS) |
| `app_version`, `build` | The app's version and build number |
| `os_version` | The system version text |
| `device` | The device model identifier |
| `note` | What the person typed, cut to 2000 characters (empty for automatic reports) |
| `log` | Up to 300 lines of the playback log, with server names replaced by `server-1`, `server-2`… and logins, tokens and stream addresses removed |

Never sent: logins, passwords, playlist names, titles, stream addresses, or any account.

## What the apps declare

- Privacy manifests (iOS and Mac) list **Device ID**, **Other Diagnostic Data** and **Other User Content**, linked to the device's install ID, not used for tracking, purpose App Functionality.
- App Store Connect's privacy answers must match: Data Linked to You → Identifiers (Device ID), Diagnostics (Other Diagnostic Data), User Content (Other User Content); none used for tracking.
- The privacy policy (`legal/privacy.md`) says "off until you turn it on" and "deleted after 30 days".

## What the server must do (check these; they have not been verified from the repository)

The "deleted after 30 days" statement is only true if the server enforces it. Run these in the Supabase SQL editor of the project that hosts `submit-log`:

1. **The table is not readable by the public key.**
   ```sql
   select c.relname, c.relrowsecurity as rls_on, c.relforcerowsecurity as rls_forced
   from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r';

   select schemaname, tablename, policyname, roles, cmd, qual, with_check from pg_policies where schemaname = 'public';
   ```
   Expected: row-level security on for the reports table, and **no** policy that lets `anon` or `authenticated` `select`, `update` or `delete`. Inserts should come only through the edge function (service role).
2. **Retention is enforced by a scheduled job.**
   ```sql
   select jobid, schedule, command from cron.job;
   ```
   Expected: a job that deletes reports older than 30 days (for example `delete from public.<reports_table> where created_at < now() - interval '30 days'`) and runs at least daily. If there is none, add one, or change the policy text to the real retention.
3. **The edge function accepts only the fields above** and rejects oversized bodies. Read its source (`supabase functions download submit-log` or the dashboard) and confirm it stores nothing else (no IP address, no headers) and limits the body size.
4. **Deletion on request.** The policy promises deletion by report number. Confirm there is a way to run `delete from public.<reports_table> where install_id = '<number>'` and keep a note of who can do it.
5. **Access.** Only the developer's account can open the project; no shared API key with `service_role` is in any app or in this repository.

Record the date of the check and the result below.

| Date | Checked by | Result |
|---|---|---|
| | | |
