# Single sign-on and user management

Keycloak is the identity layer. Everything below happens in its admin
console at `https://auth.<domain>/admin/`, realm `openapk`.

## Local accounts

Users > Add user. Set email (it doubles as the username), then a password
under Credentials. Enabling "Temporary" forces a change at first sign-in.
With `SELF_REGISTRATION=false` (the default) this is the only way accounts
appear unless you connect an identity provider.

## SAML or OIDC (Entra ID, Okta, ADFS, PingFederate, Keycloak)

Identity providers > Add provider. Keycloak brokers the login: users still
sign in at `auth.<domain>`, click your provider, and come back with a
linked account. Recommended settings:

- First login flow: `first broker login`, with "Trust email" on so
  accounts are matched by email.
- Sync mode: `force`, so name and email changes upstream propagate.
- To hide the local login form entirely, set the realm's browser flow to
  redirect to the provider (Authentication > Flows > duplicate "browser",
  add "Identity Provider Redirector" with the provider alias as default).

The two clients the platform uses (`openapk-frontend` for the web apps,
`openbin-cli` for the CLI's device flow) need no changes.

## LDAP / Active Directory

User federation > Add LDAP provider. Use a read-only bind account, map
`mail` to email, and enable "Import users" so profiles exist locally for
project sharing and mentions. Periodic sync keeps them current.

## Roles inside the platform

Project access (owner, editor, viewer) is managed in the apps themselves.
The platform administrator is the email in `ADMIN_EMAIL`; add more with a
comma-separated list in `.env` and `bin/openbin-enterprise up`.

## Email from Keycloak

Password resets and verification emails need SMTP: Realm settings > Email.
The platform's own notification emails are disabled in this distribution.
