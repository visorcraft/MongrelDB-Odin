# Error handling

Every procedure in the Odin client returns a `Mongrel_Error` alongside its
result. `.None_` means success; every other variant is a failure category. This
is the complete reference: the error variants, the HTTP-status mapping, the
daemon's error envelope, and recovery patterns for each category.

---

## The error model

`Mongrel_Error` is a single typed enum you `switch` on to branch on the
*category* of failure:

```odin
Mongrel_Error :: enum {
	None_,
	Http,
	Json,
	Auth,
	Not_Found,
	Conflict,
	Query,
	Response_Too_Large,
	Already_Committed,
}
```

`mongrel_error_string(e)` returns a short human-readable label for an error
variant (handy for logging). The daemon's structured error code is not decoded
separately by the client; it is part of the response body, which is not surfaced
on the error path. Branch on the category.

Throughout this guide the client is imported as `import m "mdb:mongreldb"` and
all calls use the free-function form (e.g. `m.schema_for(db, ...)`,
`m.mongrel_error_string(err)`).

## Error variant reference

| Variant | Meaning | Typical cause |
|---------|---------|---------------|
| `.None_` | success | - |
| `.Http` | transport failure or 3xx/5xx | Connection refused, timeout, DNS failure, redirect, daemon crash |
| `.Json` | malformed JSON response | The daemon returned a body the client's parser could not decode |
| `.Auth` | HTTP 401 or 403 | Missing/bad credentials against an auth-enabled daemon |
| `.Not_Found` | HTTP 404 | Missing table, missing schema, dropped resource |
| `.Conflict` | HTTP 402 or 409 | Unique, foreign-key, check, or trigger violation at commit |
| `.Query` | HTTP 400 or other non-2xx | Malformed request, server-side failure, everything else |
| `.Response_Too_Large` | body > 256 MB | A response exceeded the `max_response_bytes` cap |
| `.Already_Committed` | client-side | `commit`/`rollback` on a spent transaction |

## The daemon's error envelope

When the daemon rejects a request, it returns a JSON envelope like:

```json
{
  "status": "aborted",
  "error": {
    "code": "UNIQUE_VIOLATION",
    "message": "duplicate key in column 1",
    "op_index": 0
  }
}
```

Structured codes you will commonly see:

| code | Meaning |
|------|---------|
| `UNIQUE_VIOLATION` | A unique/PK constraint rejected the commit |
| `FK_VIOLATION` | A foreign-key reference was missing |
| `CHECK_VIOLATION` | A check constraint or trigger rejected the commit |
| `NOT_FOUND` | A named resource (table, schema) does not exist |

The client maps the HTTP status to the variant above; the message body itself
is not surfaced on the error path (the failed response body is discarded), so
branch on the variant and correlate with server logs when you need the detail.

## HTTP status -> variant mapping

| HTTP status | Variant | Notes |
|-------------|---------|-------|
| 2xx | `.None_` | Success |
| 3xx | `.Http` | Redirects are treated as transport errors (the client does not follow them) |
| 401, 403 | `.Auth` | Bad/missing credentials |
| 402, 409 | `.Conflict` | Constraint violation at commit |
| 404 | `.Not_Found` | Resource not found |
| 400 | `.Query` | Malformed request / bad query |
| 5xx | `.Http` | Daemon-side failure |
| other non-2xx | `.Query` | Catch-all |

## Discriminating errors

`switch` on the returned error:

```odin
_, err := m.schema_for(db, "missing_table")
switch err {
case .None_:       // ok
case .Not_Found:   fmt.eprintln("table does not exist")
case .Conflict:    fmt.eprintln("unexpected conflict on a read")
case .Auth:        fmt.eprintln("bad credentials")
case .Query:       fmt.eprintf("server error: %s\n", m.mongrel_error_string(err))
case .Http:        fmt.eprintf("can't reach daemon: %s\n", m.mongrel_error_string(err))
}
```

## Recovery patterns

### Auth failure - do not retry blindly

A retry will not fix bad credentials. Surface the error to the caller or
operator.

```odin
if err == .Auth {
	// Refresh credentials from your secret store, or fail fast.
	return
}
```

### Not found - fall back, do not crash

For lookups by primary key, a 404 may be a normal "absent" result (when the
table itself is missing). Treat it accordingly.

```odin
if err == .Not_Found {
	// table missing - treat as empty
}
```

Note: a `pk` query against an existing table returns zero rows, not a 404;
`.Not_Found` here means the table itself is missing.

### Constraint conflict - the engine already rolled back

```odin
if err == .Conflict {
	// The engine already discarded the whole batch. Nothing to undo.
}
```

### Transient failure - retry with an idempotency key

`.Http` (for 5xx and transport failures) and `.Query` (for 400s) cover
transport and transient server failures. With an idempotency key, retrying a
transaction is safe (see [transactions.md](transactions.md)).

```odin
for attempt in 0..<3 {
	results, err = m.commit(&txn, "stable-key")
	if err == .None_ { break }
	if err == .Auth || err == .Conflict { break } // not transient
	// sleep and retry
}
```

### Already committed - a programming bug

`.Already_Committed` means `commit` or `rollback` was called twice on the same
`Transaction`. Fix the caller rather than catching it at runtime.

### Network failure - check connectivity

`.Http` wraps the libcurl error on the transport layer. Check whether the daemon
is running and reachable on the configured URL.

### Response too large

`.Response_Too_Large` means a response body exceeded the 256 MB
`max_response_bytes` cap. Narrow your query (projection, limit, range predicate)
or page the result set.

## Quick reference

```odin
// Category checks:
if err == .Not_Found       { /* ... */ }
if err == .Conflict        { /* ... */ }
if err == .Auth            { /* ... */ }
if err == .Query           { /* ... */ }
if err == .Http            { /* ... */ }
if err == .Response_Too_Large { /* ... */ }
if err == .Already_Committed { /* ... */ }

// Human-readable label:
label := m.mongrel_error_string(err)
```

## Next steps

- [transactions.md](transactions.md) - constraint handling and retries in context
- [auth.md](auth.md) - credential management
