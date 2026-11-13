# Single sign-on and user management

Keycloak is the identity layer. The common cases have installer
commands; everything else is in its admin console.

## Who can get an account

Three ways, which can be combined:

| | How people get in | Set up with |
|---|---|---|
| Self sign-up | "Register" on the sign-in page: email, name, password | on by default for installs reached by IP address |
| LDAP / Active Directory | their directory username or email, and directory password | one command, below |
| Administrator | an admin creates each account | the Keycloak console |

The Keycloak console is at `https://<ip>/auth/admin/` (IP layout) or
`https://auth.<domain>/admin/`, realm `openapk`; sign in as `admin` with
`KEYCLOAK_ADMIN_PASSWORD` from `.env`.

## Self sign-up

```sh
./install.sh --self-registration        # open
./install.sh --no-self-registration     # closed
```

Open means anyone who can reach the URL can create an account, which is
the point on a private network: a team starts without an administrator
creating every account. Close it once everyone is in, or when accounts
come from your directory. No email is sent (there is no mail server to
rely on inside an air gap), so addresses are not verified and "forgot
password" only works after you configure SMTP (last section); until then
an administrator resets passwords in the Keycloak console.

## Local accounts created by an administrator

Users > Add user. Set email (it doubles as the username), then a password
under Credentials. Enabling "Temporary" forces a change at first sign-in.

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

The clients the platform uses (`openbin-frontend` and `openapk-frontend`
for the web apps, `openbin-cli` for the CLI's device flow) need no changes.

## LDAP / Active Directory

```sh
bin/openbin-enterprise ldap connect \
    --url ldaps://dc1.corp.example:636 \
    --bind-dn 'CN=svc-openbin,OU=Service,DC=corp,DC=example' \
    --users-dn 'OU=Staff,DC=corp,DC=example' \
    --vendor ad \
    --ca-cert corp-root-ca.pem
```

It asks for the bind account's password (or reads `--bind-password-file`),
checks that the directory answers and accepts that account, saves the
connection, and reads the users in. From then on people sign in with
their directory username (`sAMAccountName` for `--vendor ad`, `uid`
otherwise) or email, and their directory password.

- The connection is read-only. Nothing is written to the directory, and
  passwords are checked against it on every sign-in, never copied.
- Each person needs an email address (`mail`) in the directory.
- `--filter '(memberOf=CN=RE-Team,OU=Groups,DC=corp,DC=example)'` limits
  who can sign in.
- `--ca-cert` is for `ldaps://` with a certificate from a private CA.
- The directory is re-read every hour; `ldap sync` does it now,
  `ldap status` shows the connection, `ldap remove` disconnects.
- Running `ldap connect` again updates the existing connection.
- The same options exist on the installer as `--ldap-url`,
  `--ldap-bind-dn`, `--ldap-users-dn` and so on, to connect at install
  time; sign-up then defaults to closed.
- The bind password is stored in Keycloak's database only, not in `.env`.

Group-to-role mapping and other fine-tuning are in the Keycloak console
under User federation > ldap.

## Roles inside the platform

Project access (owner, editor, viewer) is managed in the apps themselves.
The platform administrator is the email in `ADMIN_EMAIL`; add more with a
comma-separated list in `.env` and `bin/openbin-enterprise up`.

## Email from Keycloak

Password resets and verification emails need SMTP: Realm settings > Email.
The platform's own notification emails are disabled in this distribution.
