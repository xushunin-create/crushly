// delete-account: permanently deletes the calling user.
//
// Runs server-side with the service role (never shipped in the app). Steps:
//   1. Verify the caller's own access token — a user can only delete themselves.
//   2. Remove every object under profile-photos/<uid>/ (storage ownership would otherwise block deletion).
//   3. Delete the auth user. Foreign keys cascade to profiles, sessions, signals, matches, connections,
//      find requests, blocks, shield state, prefs, device tokens, outbox rows and analytics.
//      Reports are retained for moderation with user ids nulled and a profile snapshot
//      (see migration §4.2 and docs/MODERATION.md).
//
// Deploy: supabase functions deploy delete-account   (JWT verification stays on)

import { createClient } from "jsr:@supabase/supabase-js@2";

const BUCKET = "profile-photos";

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? Deno.env.get("SUPABASE_SECRET_KEY");
  if (!url || !serviceKey) return json({ error: "server_misconfigured" }, 500);

  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!token) return json({ error: "not_authenticated" }, 401);

  const admin = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // 1. Who is asking? getUser validates the token with the auth server.
  const { data: userData, error: userError } = await admin.auth.getUser(token);
  if (userError || !userData?.user) return json({ error: "not_authenticated" }, 401);
  const uid = userData.user.id;

  // 2. Photos.
  const bucket = admin.storage.from(BUCKET);
  for (let page = 0; page < 20; page++) {
    const { data: files, error } = await bucket.list(uid, { limit: 100 });
    if (error) return json({ error: "storage_list_failed" }, 500);
    if (!files || files.length === 0) break;
    const { error: removeError } = await bucket.remove(files.map((f) => `${uid}/${f.name}`));
    if (removeError) return json({ error: "storage_remove_failed" }, 500);
  }

  // 3. The account itself (cascades in the database).
  const { error: deleteError } = await admin.auth.admin.deleteUser(uid);
  if (deleteError) {
    console.error("deleteUser failed", { uid, message: deleteError.message });
    return json({ error: "delete_failed" }, 500);
  }

  console.log("account deleted", { uid });
  return json({ deleted: true });
});
