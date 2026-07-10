# Security

This document describes the security properties of the MongrelDB Odin client
and how to report vulnerabilities.

## Overview

The MongrelDB Odin client is an Odin library that talks to `mongreldb-server`
over HTTP using libcurl (via a small C FFI wrapper). The client itself holds no
encryption keys and stores no data at rest; it is a thin request/response layer
over the daemon.

## Client security properties

- The client communicates with `mongreldb-server` over plain HTTP. The
  daemon binds to `127.0.0.1` by default - traffic stays on the loopback
  interface. For remote or multi-tenant deployments, terminate TLS in a
  reverse proxy (nginx, Caddy) in front of the daemon.
- The client supports Bearer token and HTTP Basic auth, matching the
  daemon's `--auth-token` and `--auth-users` modes. Credentials are sent only
  in the `Authorization` header and are never logged by the client.
- The client guards against CR/LF in credentials: a token or username
  containing a carriage return or newline is rejected (mapped to `.Query`)
  rather than sent. This prevents a malicious credential from injecting extra
  header lines through the auth header (request smuggling).
- The native condition API and query builder accept typed parameters (column
  ids, typed `JSONValue`s) - no string interpolation, no SQL injection surface.
  User-supplied values are serialized as typed JSON, not concatenated into
  queries.
- **WARNING - raw SQL:** the `sql()` procedure sends a raw SQL string to the
  server. It does NOT parameterize or sanitize input, and the client never
  interprets SQL locally. Never interpolate untrusted user input into SQL
  statements - use parameterized queries where the server supports them, or
  validate/escape input yourself. (The native condition API and query builder
  remain type-safe and are not affected.)
- Idempotency keys are caller-supplied opaque strings; the client does not
  derive or store them.
- The bundled JSON parser is a strict recursive-descent decoder that rejects
  malformed input (returning `.Json`) rather than reading out of bounds. It
  only allocates from the caller's `context.allocator`.
- Response bodies are capped at `max_response_bytes` (256 MB); a larger body is
  aborted and reported as `.Response_Too_Large` rather than growing
  unbounded. The libcurl write callback bounds-checks every write against the
  pre-allocated buffer and refuses to overflow.

## Daemon security (mongreldb-server)

The client is a consumer of `mongreldb-server`. The daemon's security posture:

- Binds to `127.0.0.1` only - not accessible from other machines.
- **No authentication by default** - any local process can query, write, or
  delete data. Enable `--auth-token` or `--auth-users` for any shared host.
- No TLS - traffic is plaintext on the loopback interface.
- No rate limiting or request size caps.

For remote access or multi-tenant environments, place a reverse proxy (nginx,
Caddy) in front with TLS termination and authentication. Do not expose the
daemon directly to a network.

## Input validation

- The query builder produces typed JSON requests. Conditions are normalized to
  the engine's canonical fields (`column` -> `column_id`, `min`/`max` ->
  `lo`/`hi`); values are emitted as typed `JSONValue`s, not interpolated
  strings.
- Table names in URL paths are percent-escaped (`url_path_escape`) so a name
  containing `/`, `?`, `#`, or spaces cannot inject extra segments or break
  routing.
- Server and network errors are mapped to the typed `Mongrel_Error` enum
  (`.Auth`, `.Not_Found`, `.Conflict`, `.Query`, `.Http`), not leaked as
  generic failures.

## Dependency security

The MongrelDB Odin client has one runtime dependency beyond the Odin core
library: libcurl. Keep libcurl patched via your system package manager. Report
dependency vulnerabilities through GitHub's Dependabot alerts or the private
vulnerability reporting flow below.

## Reporting a vulnerability

**Do not file a public GitHub issue, discussion, or pull request for security
problems.** Report privately through **GitHub's private vulnerability
reporting**:

1. Go to the repository's **Security** tab.
2. Click **Report a vulnerability**.
3. Fill in the advisory form with the details below.

This keeps the report confidential between you and the maintainers until a fix
is ready. Please include as much as you can:

- a description of the issue and its impact,
- step-by-step reproduction steps,
- the MongrelDB Odin client version, Odin version, and OS,
- the `mongreldb-server` version if relevant,
- the relevant configuration, error output, or a proof-of-concept,
- a suggested fix or mitigation, if you have one.

### What to expect

- **Acknowledgement** of your report within a few days.
- An initial assessment and, where confirmed, a remediation plan.
- Progress updates through the private advisory thread until the issue is
  resolved.
- Credit for your responsible disclosure in the advisory, unless you prefer to
  remain anonymous.

We ask that you give us a reasonable opportunity to ship a fix before any
public disclosure.
