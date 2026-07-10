# MongrelDB Odin Client - Guides

Task-focused guides for the pure-Odin MongrelDB HTTP client. For the full API
surface in one place, see the root [README](../README.md).

| Guide | What it covers |
|-------|----------------|
| [quickstart.md](quickstart.md) | Install, start the daemon, write and run your first program, common pitfalls |
| [transactions.md](transactions.md) | Single puts vs. batch transactions, idempotency keys, constraint handling, rollback |
| [queries.md](queries.md) | Every native index condition: PK, range, bitmap, full-text, projection, limits |
| [sql.md](sql.md) | CREATE TABLE, INSERT/UPDATE/DELETE/SELECT, CREATE TABLE AS SELECT, recursive CTEs, window functions |
| [auth.md](auth.md) | Bearer token and Basic auth modes, user/role management via SQL |
| [errors.md](errors.md) | The `Mongrel_Error` enum, HTTP-status mapping, recovery patterns |

## Where to start

- **New to the client?** Start with [quickstart.md](quickstart.md).
- **Writing data?** Read [transactions.md](transactions.md).
- **Reading data?** Read [queries.md](queries.md) for indexed lookups, or
  [sql.md](sql.md) for joins, CTEs, and analytics.
- **Securing a deployment?** Read [auth.md](auth.md).
- **Debugging a failure?** Read [errors.md](errors.md).

## How the client is structured

The library is the `mongreldb/` directory (declared as `package mongreldb`),
three source files:

- `mongreldb.odin` - the public API: `connect`, CRUD, query builder, transactions, SQL, schema.
- `json.odin` - a self-contained `JSONValue` union, ordered-object type, parser, and serializer.
- `curl.odin` - a thin libcurl C-FFI binding (Odin's `core:net` is a low-level sockets layer with no HTTP client).

Import the library through a collection named `mdb` that points at your repo
root, then `import m "mdb:mongreldb"`. See [quickstart.md](quickstart.md)
for the exact build commands.
