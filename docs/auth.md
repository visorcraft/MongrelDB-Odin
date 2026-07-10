# Authentication & Authorization

A `mongreldb-server` daemon runs in one of three modes:

1. **Open** (default) - no auth required.
2. **Bearer token** (`--auth-token <TOKEN>`) - every request must carry an
   `Authorization: Bearer <TOKEN>` header.
3. **HTTP Basic** (`--auth-users`) - every request must carry an
   `Authorization: Basic <base64(user:pass)>` header.

The Odin client supports all three through the `Options` struct passed to
`connect`. This guide shows each mode and how to manage users and roles via SQL
when the server is in Basic mode.

---

## Bearer token mode

Start the daemon with a token:

```sh
mongreldb-server --auth-token s3cret-token
```

Connect with `Options.token`. The token is sent as `Authorization: Bearer ...`
on every request.

```odin
db := mongreldb.connect("http://127.0.0.1:8453", mongreldb.Options{
	token = "s3cret-token",
})

ok, err := db.health()
if err == .Auth {
	fmt.eprintln("bad or missing token")
	return
}
```

A missing or wrong token surfaces as `.Auth` (HTTP 401/403).

### Where the token comes from

Hard-coding secrets in source is bad practice. Read it from the environment:

```odin
import "core:os"

token, found := os.lookup_env("MONGRELDB_TOKEN")
if !found || token == "" {
	fmt.eprintln("MONGRELDB_TOKEN not set")
	return
}
db := mongreldb.connect("http://127.0.0.1:8453", mongreldb.Options{token = token})
```

## Basic auth mode

Start the daemon with a users file or inline users:

```sh
mongreldb-server --auth-users
```

Connect with `Options.username` / `Options.password`:

```odin
db := mongreldb.connect("http://127.0.0.1:8453", mongreldb.Options{
	username = "admin",
	password = "s3cret",
})
```

The client base64-encodes `username:password` and sets `Authorization: Basic ...`
on every request.

## Token takes precedence

A Bearer token takes precedence over Basic credentials. The rule holds if you
ever set both; in practice you pick one.

## Request-smuggling guard

The client refuses to send a token or username that contains a CR or LF
character. This prevents a malicious credential from injecting extra header
lines through the auth header (request smuggling). Such a credential surfaces as
`.Query` rather than being sent.

## User and role management via SQL

When the daemon is in Basic auth mode, users and roles live in the catalog and
are managed with SQL. Run these statements through `sql`.

### Create a user

```odin
_, _ = db.sql("CREATE USER alice WITH PASSWORD 'hunter2'")
```

### Alter a user

Change a password:

```odin
_, _ = db.sql("ALTER USER alice WITH PASSWORD 'new-password'")
```

Grant the admin role:

```odin
_, _ = db.sql("ALTER USER alice ADMIN")
```

`ALTER USER ... ADMIN` is how you promote a user to full administrative
privileges (table creation/drop, compaction, user management). Use it sparingly.

### Drop a user

```odin
_, _ = db.sql("DROP USER alice")
```

### Roles and grants

```odin
_, _ = db.sql("CREATE ROLE analyst")
_, _ = db.sql("GRANT SELECT ON orders TO analyst")
_, _ = db.sql("GRANT analyst TO alice")
_, _ = db.sql("REVOKE SELECT ON orders FROM analyst")
_, _ = db.sql("DROP ROLE analyst")
```

Exact grant syntax mirrors the server's SQL flavor; consult the server's SQL
reference for the full `GRANT`/`REVOKE` grammar available in your build.

## Common pitfalls

**Auth errors look like other errors without the variant.** A 401/403 maps to
`.Auth`; a 404 maps to `.Not_Found`. Always `switch` on the error variant rather
than string-matching labels.

**Forgetting to set auth in production.** A client built with empty `Options`
sends no credentials. Against an auth-enabled daemon, every call fails with
`.Auth`. Centralize client construction so the auth fields are never
accidentally dropped.

**One client is one identity.** A `Client` carries one set of credentials. If
you serve multiple authenticated users, build a client per user with that user's
token.

**Token in version control.** Put secrets in the environment, a secret manager,
or a file outside the repo. Never commit a real token.

## Next steps

- [errors.md](errors.md) - `.Auth` and the rest of the error variants
- [quickstart.md](quickstart.md) - the full end-to-end walkthrough
