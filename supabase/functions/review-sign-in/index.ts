// review-sign-in: lets App Review sign in to ONE fixed account without receiving an email.
//
// The app is passwordless (email OTP), and App Review can't read a USC inbox. For exactly REVIEW_EMAIL, the app skips
// sending a code and posts { email, code } here instead. If the code matches REVIEW_CODE, this function mints a normal
// magic-link session for that account and returns its tokens. The account never gets a password, so
// verify_production.sql check 7 still passes.
//
// Secrets (Dashboard → Edge Functions → Secrets, or `supabase secrets set`):
//   REVIEW_EMAIL   e.g. crushly-appreview@usc.edu   (must match AppReview.email in the app)
//   REVIEW_CODE    6 random digits, given to Apple in App Review Information
// Unset either secret to turn the reviewer login off (the function then rejects everything).
//
// Brute force: every attempt counts against app_settings.rate_limits.review_sign_in for the reviewer's user id
// (10/hour, 30/day), so guessing a 6-digit code is impractical.
//
// Deploy: supabase functions deploy review-sign-in --no-verify-jwt   (called before the user has a session)

import { createClient } from "jsr:@supabase/supabase-js@2";

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function safeEqual(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a);
  const y = new TextEncoder().encode(b);
  if (x.length !== y.length) return false;
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
  return diff === 0;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? Deno.env.get("SUPABASE_SECRET_KEY");
  const reviewEmail = (Deno.env.get("REVIEW_EMAIL") ?? "").trim().toLowerCase();
  const reviewCode = (Deno.env.get("REVIEW_CODE") ?? "").trim();
  if (!url || !serviceKey) return json({ error: "server_misconfigured" }, 500);
  if (!reviewEmail || !/^\d{6}$/.test(reviewCode)) return json({ error: "invalid_code" }, 401);

  let body: { email?: unknown; code?: unknown };
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid_input" }, 400);
  }
  const email = typeof body.email === "string" ? body.email.trim().toLowerCase() : "";
  const code = typeof body.code === "string" ? body.code.trim() : "";
  if (email !== reviewEmail) return json({ error: "invalid_code" }, 401);

  const admin = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // Create the account on first use: confirmed, no password (OTP-only like everyone else).
  const { error: createError } = await admin.auth.admin.createUser({ email, email_confirm: true });
  if (createError && !/already|exists|registered/i.test(createError.message)) {
    console.error("review createUser failed", { message: createError.message });
    return json({ error: "server_error" }, 500);
  }

  // A magic-link token for the account. Nothing is emailed; we redeem it below.
  const { data: link, error: linkError } = await admin.auth.admin.generateLink({ type: "magiclink", email });
  if (linkError || !link?.user || !link.properties?.hashed_token) {
    console.error("review generateLink failed", { message: linkError?.message });
    return json({ error: "server_error" }, 500);
  }

  // Count the attempt before checking the code.
  const { error: limitError } = await admin.rpc("enforce_rate_limit", {
    u: link.user.id,
    p_bucket: "review_sign_in",
  });
  if (limitError) {
    if (limitError.message.includes("rate_limited")) return json({ error: "rate_limited" }, 429);
    console.error("review rate limit failed", { message: limitError.message });
    return json({ error: "server_error" }, 500);
  }

  if (!safeEqual(code, reviewCode)) return json({ error: "invalid_code" }, 401);

  const verifier = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: verified, error: verifyError } = await verifier.auth.verifyOtp({
    token_hash: link.properties.hashed_token,
    type: "magiclink",
  });
  if (verifyError || !verified?.session) {
    console.error("review verifyOtp failed", { message: verifyError?.message });
    return json({ error: "server_error" }, 500);
  }

  console.log("review sign-in", { uid: link.user.id });
  return json({
    access_token: verified.session.access_token,
    refresh_token: verified.session.refresh_token,
  });
});
