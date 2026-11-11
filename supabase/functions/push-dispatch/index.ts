// push-dispatch: drains notification_outbox and delivers via APNs.
//
// Invoked every minute by pg_cron (see docs/NOTIFICATIONS.md). Not callable from the app:
// requests must carry the shared secret in `x-dispatch-secret`.
//
// Lock-screen copy is deliberately discreet — never a name, photo, place or distance. Even a mutual
// match only says something happened; details are shown after the user opens and unlocks the app.
//
// Required secrets: APNS_KEY_P8 (contents of the .p8), APNS_KEY_ID, APNS_TEAM_ID, APNS_TOPIC (bundle id),
// PUSH_DISPATCH_SECRET. SUPABASE_URL and the service key are provided by the runtime.

import { createClient } from "jsr:@supabase/supabase-js@2";

type Claimed = {
  id: string;
  user_id: string;
  kind: string;
  payload: Record<string, unknown>;
  tokens: { token: string; apns_env: "sandbox" | "production" }[];
};

// Discreet copy. `route` is read by the app to deep-link after unlock (see NotificationRouter.swift).
function render(n: Claimed): { title: string; body: string; route: string } | null {
  const match = typeof n.payload.match_id === "string" ? `match:${n.payload.match_id}` : "signals";
  switch (n.kind) {
    case "anonymous_signal":    return { title: "Crushly", body: "Someone nearby felt a spark.", route: "signals" };
    case "heart_sync":          return { title: "Crushly", body: "Someone felt it too. Open Crushly to see.", route: match };
    case "crossed_hearts":      return { title: "Crushly", body: "You missed the moment, not each other.", route: match };
    case "find_request":        return { title: "Crushly", body: "You have a new request.", route: match };
    case "find_accepted":       return { title: "Crushly", body: "Your request was accepted.", route: match };
    case "connection_action":   return { title: "Crushly", body: "You have something new waiting.", route: match };
    case "connection_reminder": return { title: "Crushly", body: "A connection is waiting on you.", route: match };
    case "connection_expired":  return { title: "Crushly", body: "A saved connection has expired.", route: "signals" };
    case "pulse_expiring":      return { title: "Crushly", body: "Your Pulse ends in 5 minutes.", route: "around" };
    default:                    return null;
  }
}

// ---- APNs provider token (ES256 JWT), cached for 50 minutes ------------------------------------

let cachedJWT: { token: string; at: number } | null = null;

function b64url(data: ArrayBuffer | Uint8Array | string): string {
  const bytes = typeof data === "string" ? new TextEncoder().encode(data) : new Uint8Array(data);
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function providerToken(keyP8: string, keyId: string, teamId: string): Promise<string> {
  if (cachedJWT && Date.now() - cachedJWT.at < 50 * 60 * 1000) return cachedJWT.token;
  const der = Uint8Array.from(
    atob(keyP8.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "")),
    (c) => c.charCodeAt(0),
  );
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const header = b64url(JSON.stringify({ alg: "ES256", kid: keyId }));
  const claims = b64url(JSON.stringify({ iss: teamId, iat: Math.floor(Date.now() / 1000) }));
  const input = `${header}.${claims}`;
  // WebCrypto returns the raw r||s signature, which is exactly the JWS ES256 format.
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(input));
  cachedJWT = { token: `${input}.${b64url(sig)}`, at: Date.now() };
  return cachedJWT.token;
}

// ---- Handler ------------------------------------------------------------------------------------

Deno.serve(async (req) => {
  const secret = Deno.env.get("PUSH_DISPATCH_SECRET");
  if (!secret || req.headers.get("x-dispatch-secret") !== secret) {
    return new Response("forbidden", { status: 403 });
  }

  const url = Deno.env.get("SUPABASE_URL")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? Deno.env.get("SUPABASE_SECRET_KEY");
  const keyP8 = Deno.env.get("APNS_KEY_P8");
  const keyId = Deno.env.get("APNS_KEY_ID");
  const teamId = Deno.env.get("APNS_TEAM_ID");
  const topic = Deno.env.get("APNS_TOPIC");
  if (!serviceKey || !keyP8 || !keyId || !teamId || !topic) {
    return Response.json({ error: "apns_not_configured" }, { status: 500 });
  }

  const db = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data, error } = await db.rpc("claim_due_notifications", { p_limit: 200 });
  if (error) return Response.json({ error: "claim_failed", detail: error.message }, { status: 500 });

  const jwt = await providerToken(keyP8, keyId, teamId);
  const sent: string[] = [];
  let failures = 0;

  for (const n of (data ?? []) as Claimed[]) {
    const copy = render(n);
    if (!copy) continue;                       // unknown kind: left claimed, will be cancelled after 5 attempts
    const body = JSON.stringify({
      aps: { alert: { title: copy.title, body: copy.body }, sound: "default", "interruption-level": "active" },
      route: copy.route,
    });
    let delivered = false;
    for (const t of n.tokens) {
      const host = t.apns_env === "production" ? "api.push.apple.com" : "api.sandbox.push.apple.com";
      const res = await fetch(`https://${host}/3/device/${t.token}`, {
        method: "POST",
        headers: {
          authorization: `bearer ${jwt}`,
          "apns-topic": topic,
          "apns-push-type": "alert",
          "apns-priority": "10",
          "apns-collapse-id": n.kind === "anonymous_signal" ? "anonymous-signal" : n.id.slice(0, 64),
        },
        body,
      });
      if (res.ok) {
        delivered = true;
      } else {
        const reason = (await res.json().catch(() => ({}))).reason ?? res.status;
        if (res.status === 410 || reason === "BadDeviceToken" || reason === "Unregistered") {
          await db.rpc("forget_device_token", { p_token: t.token });
        } else {
          failures++;
          console.error("apns error", { kind: n.kind, status: res.status, reason });
        }
      }
    }
    if (delivered) sent.push(n.id);
  }

  if (sent.length) await db.rpc("mark_notifications_sent", { ids: sent });
  return Response.json({ claimed: data?.length ?? 0, sent: sent.length, failures });
});
