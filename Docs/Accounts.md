# FormScan accounts

FormScan 2.4.1 uses the official Supabase Swift Auth SDK 2.55.4 with PKCE.
The project is independent of reviewNfcGo: `zqptfsammjpdqqoonevu`.
`Config/AccountConfiguration.json` contains only a public origin and publishable
key. `Scripts/prepare_accounts.py` generates the bundled property list. No Google
client secret, service-role key or administrative credentials belong in the app.

## Owner setup

In Authentication → URL Configuration → Redirect URLs add:

```
com.polaca1.formscan://auth/callback/*
com.polaca1.formscan://auth/confirm/*
com.polaca1.formscan://auth/recovery/*
```

Enable Email and Confirm email. Configure a production SMTP provider for delivery
outside the restricted built-in mail service. In Google Cloud create/configure a
web OAuth client with this authorized redirect URI:

```
https://zqptfsammjpdqqoonevu.supabase.co/auth/v1/callback
```

Enable Google in Supabase and store the OAuth client ID and secret **there**.
Keep existing redirect entries used by other apps if the project is ever shared.
Google consent branding, authorized audience/test users, SMTP delivery and native
return URLs require owner configuration and a real-device acceptance test.

Read-only settings checks verify that Email, Google and email confirmation are
enabled before the publication job may replace the SideStore feeds. These checks
cannot prove the redirect allowlist or SMTP delivery. No real users are created,
read or modified by automated tests.

## Identity and lifecycle

The SDK stores sessions and PKCE verifiers in a dedicated FormScan Keychain service.
Google uses ASWebAuthenticationSession. A random callback path binds each attempt;
the app checks scheme, host, path, a single nonempty code, and rejects foreign
callbacks or implicit tokens before asking the SDK to exchange a code. Canceling
Google preserves the current state. Recovery and confirmation links are bound to
the requesting installation and are consumed once. Open recovery mail on the
same device that requested it. If the app was removed, request a new link.

Unconfirmed registration never creates a simulated session. Google users can add
a FormScan password using authenticated PUT /auth/v1/user; the UUID and email must
remain the same. Before updating the password, the app refreshes the SDK session,
fetches the authenticated user from the service, and requires the same UUID and
confirmed email. No client-side email matching grants access.

Supabase automatically links Google to the existing account when both methods use
the same verified email. Do not merge document owners by email in SQL or in the
client: the Supabase UUID remains the authority. See the official identity-linking
guide: https://supabase.com/docs/guides/auth/auth-identity-linking

- Email first: confirm the email, then use Google with that same address.
- Google first: sign in with Google, open Settings → Create or change password,
  and choose a FormScan password. Both methods then access the same account.
- Registering again is not how a Google account gets a password. The registration
  screen and generic confirmation notice explain the authenticated route without
  revealing whether an email is registered.

Stateful transport tests cover both orders through the real SDK, fresh local auth
storage, the same owner UUID and an edited document. They test the client contract,
not a Google login against the production account.

Sign-out clears the local session even if remote revocation cannot connect; it does not delete files.
The SDK refreshes sessions. A previously authenticated local session allows offline
access to its local documents; server actions still require a valid session.

## Private documents

Signed-in accounts automatically save PDFs and editable field metadata to the
private FormScan service. Guest documents stay on the device. Analysis remains
local, with all three verified inference resources bundled; there are no model
installation controls. See [Cloud.md](Cloud.md) for the storage contract, owner
migration and limits. The account-service publication check also requires the
cloud health RPC to confirm schema version 1 and a private bucket.

The pre-account Documents library is moved atomically to the first account used on
this installation, preserving edits and identifiers. Later accounts use separate
UUID directories and cannot adopt that library. Guest documents created after this
migration remain in a separate GuestDocuments directory. On account changes, open
sessions save and stop background work before a new library appears. A failed save
blocks the transition with a retry message and keeps the in-memory library for
recovery. Signing in does not prove that every local document has finished uploading.
Do not delete the app while a save error or pending-change warning is unresolved.

## Verification

Tests use the actual SDK against an injected HTTP transport and isolated local
storage: password sign-in/restoration, confirmation without session, Google PKCE,
foreign callback rejection, authenticated password updates, recovery, offline
sign-out, friendly errors and local library migration/isolation. UI tests cover
first launch, validation, example onboarding, privacy/settings, actual Files
import, document/form edits, checkbox rendering, export and table regression.
Cloud controller and HTTP transport tests cover restore, offline edits, failed
responses, ownership, simultaneous edits and deletion races. A simulator-only
service tests recovery after removing the local library, preserving text and
checkboxes, and retry after failure. It is excluded from release builds.
These tests do not replace a real Google account, SMTP delivery or real-device
cloud acceptance test.

Apple references applied: native navigation and forms, focus/autofill, Dynamic Type,
light/dark appearance, accessible controls, reduced motion and explicit privacy:
https://developer.apple.com/design/human-interface-guidelines/entering-data
https://developer.apple.com/design/human-interface-guidelines/privacy
https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession
https://supabase.com/docs/guides/auth/native-mobile-deep-linking
https://supabase.com/docs/guides/auth/auth-smtp
