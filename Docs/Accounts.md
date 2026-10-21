# FormScan accounts

FormScan 2.3 uses the official Supabase Swift Auth SDK 2.55.4 with PKCE.
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
remain the same. No client-side email matching grants access. Sign-out clears the
local session even if remote revocation cannot connect; it does not delete files.
The SDK refreshes sessions. A previously authenticated local session allows offline
access to its local documents; server actions still require a valid session.

## Documents are local

Accounts do **not** upload or synchronize PDFs. The interface explicitly explains
this. Scan, import, inference, editing and export remain local and work without
model downloads or technical settings. All three verified inference resources ship
in the app. Memory, power and thermal state choose scheduling automatically.

The pre-account Documents library is moved atomically to the first account used on
this installation, preserving edits and identifiers. Later accounts use separate
UUID directories and cannot adopt that library. Guest documents created after this
migration remain in a separate GuestDocuments directory. On account changes, open
sessions save and stop background work before a new library appears. A failed save
blocks the transition with a retry message and keeps the in-memory library for
recovery. There is no claim of device-level encryption or protection from someone
with access to the unlocked device and Files. Before removing the app, export any
PDFs that must be retained; logging back in cannot restore files that were never
uploaded.

## Verification

Tests use the actual SDK against an injected HTTP transport and isolated local
storage: password sign-in/restoration, confirmation without session, Google PKCE,
foreign callback rejection, authenticated password updates, recovery, offline
sign-out, friendly errors and local library migration/isolation. UI tests cover
first launch, validation, example onboarding, privacy/settings, actual Files
import, document/form edits, checkbox rendering, export and table regression.
These tests do not replace a real Google account or real SMTP delivery test.

Apple references applied: native navigation and forms, focus/autofill, Dynamic Type,
light/dark appearance, accessible controls, reduced motion and explicit privacy:
https://developer.apple.com/design/human-interface-guidelines/entering-data
https://developer.apple.com/design/human-interface-guidelines/privacy
https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession
https://supabase.com/docs/guides/auth/native-mobile-deep-linking
https://supabase.com/docs/guides/auth/auth-smtp
