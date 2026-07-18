<p align="center">
  <img src="assets/mongrel.png" alt="MongrelDB logo" width="250" />
</p>

<h1 align="center">MongrelDB Odin Client</h1>

<p align="center">
  <b>Pure-Odin HTTP client for MongrelDB - embedded+server database with SQL, vector search, full-text search, and AI-native retrieval.</b>
  <br />
  No package manager required - just source files. Talks to the daemon's JSON API over libcurl (via a small C FFI wrapper) and bundles a self-contained JSON layer. The API mirrors the MongrelDB PHP and Go clients.
</p>

<p align="center">
  <a href="#license"><img src="https://img.shields.io/badge/license-MIT%20OR%20Apache--2.0-blue.svg" alt="License" /></a>
  <a href="https://github.com/visorcraft/MongrelDB-Odin/actions/workflows/ci.yml"><img src="https://github.com/visorcraft/MongrelDB-Odin/actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
  <a href="https://github.com/visorcraft/MongrelDB/releases"><img src="https://img.shields.io/badge/server-v0.59.1-blue.svg" alt="MongrelDB server" /></a>
  <a href="https://odin-lang.org/"><img src="https://img.shields.io/badge/Odin-dev--2026--60a35f.svg" alt="Odin" /></a>
</p>

## Package

| Surface | Package | Install |
|---|---|---|
| Odin client | `mongreldb` | copy the `mongreldb/` directory into your project, or add it as a git submodule |

## Requirements

- **Odin** (recent dev build) - this client uses `core:fmt`, `core:mem`, `core:strings`, `core:os`, and C FFI
- **libcurl** (the HTTP transport). On Debian/Ubuntu install `libcurl4-openssl-dev`; on Fedora `curl-devel`. The client links it via `foreign import lib "system:curl"`.
- A running [`mongreldb-server`](https://github.com/visorcraft/MongrelDB) daemon

## What It Provides

- **Typed CRUD** over the Kit transaction endpoint: `put` (with optional idempotency keys for safe retries), `upsert` (insert-or-update on PK conflict), and `delete`/`delete_by_pk` by row id or primary key. Cells are a `{column_id, JSONValue}` pair flattened to the server's on-wire `[col_id, value, ...]` array.
- **Fluent query builder** that pushes conditions down to the engine's specialized indexes for sub-millisecond lookups: primary key, learned-range, bitmap equality, null checks, and FM-index full-text search. Friendly aliases (`column` -> `column_id`, `min`/`max` -> `lo`/`hi`) are translated to the server's on-wire keys.
- **Idempotent batch transactions** - operations staged locally on a `Transaction` and committed atomically, with the engine enforcing unique, foreign-key, and check constraints at commit time. Idempotency keys return the original response on duplicate commits, even after a crash.
- **Full SQL access** through the DataFusion-backed `/sql` endpoint (JSON format requested): recursive CTEs, window functions, `CREATE TABLE AS SELECT`, materialized views, and multi-statement execution.
- **History retention** controls: get and set the history window, query older epochs with `AS OF EPOCH`, and read the earliest retained epoch.
- **Schema management**: typed table creation, full schema catalog (`map[string]JSONValue`), and per-table descriptors.
- **Typed errors**: a single `Mongrel_Error` enum you `switch` on - `.Auth` (401/403), `.Not_Found` (404), `.Conflict` (409), `.Query` (everything else non-2xx), `.Http` (transport), `.Json` (malformed response), plus `.Response_Too_Large` and `.Already_Committed`.
- **Self-contained JSON layer** - a local `JSONValue` union, ordered-object type, strict recursive-descent parser, and compact serializer. No dependency on any particular version of `core:encoding/json`.

## Examples

Task-focused, commented guides live in [`docs/`](docs):

- [Quickstart](docs/quickstart.md) - install, start the daemon, write and run a complete program.
- [Transactions](docs/transactions.md) - batch commits, idempotency keys, constraint handling.
- [Queries](docs/queries.md) - every native condition type and the index it pushes down to.
- [SQL](docs/sql.md) - recursive CTEs, window functions, advanced SQL.
- [Authentication](docs/auth.md) - Bearer token, HTTP Basic, and open modes.
- [Errors](docs/errors.md) - the typed error set and recovery patterns.

## Quick Example

```odin
package main

import "core:fmt"
import m "mdb:mongreldb"

main :: proc() {
	// Connect to a running mongreldb-server daemon.
	db := m.connect("http://127.0.0.1:8453", m.Options{})

	ok, err := m.health(db)
	if err != .None_ || !ok {
		fmt.eprintf("daemon not reachable: %s\n", m.mongrel_error_string(err))
		return
	}

	// Create a table. Column ids are stable on-wire identifiers.
	cols := []m.Column{
		{id = 1, name = "id", ty = "int64", primary_key = true},
		{id = 2, name = "customer", ty = "varchar"},
		{id = 3, name = "amount", ty = "float64"},
	}
	tid, cerr := m.create_table(db, "orders", cols)
	if cerr != .None_ { panic(m.mongrel_error_string(cerr)) }

	// Insert rows (cells pair column id + value).
	r := []m.Cell{
		{1, m.int_value(1)},
		{2, m.string_value("Alice")},
		{3, m.float_value(99.5)},
	}
	pres, perr := m.put(db, "orders", r, "")
		defer m.json_destroy(pres)
	if perr != .None_ { panic(m.mongrel_error_string(perr)) }

	// Query with a native index condition (learned-range index).
	qb := m.query(db, "orders")
	defer m.free_query_builder(&qb)
	range_params := range_for(3, 100.0, 0.0)
		defer m.json_object_destroy(range_params)
		m.where_(&qb, "range_f64", range_params)
	rows, qerr := m.execute(&qb)
		defer free_rows(rows)
	if qerr != .None_ { panic(m.mongrel_error_string(qerr)) }
	fmt.printf("rows: %d\n", len(rows))

	n, _ := m.count(db, "orders")
	fmt.printf("count: %lld\n", n) // 1
}

// range_for builds a range condition payload {"column": id, "min": lo}.
// The caller owns the returned object and must destroy it with
// json_object_destroy when done.
range_for :: proc(id: i64, lo, hi: f64) -> m.JSONObject {
	o := m.json_object_make()
	m.json_object_set(&o, "column", m.int_value(id))
	m.json_object_set(&o, "min", m.float_value(lo))
	if hi > 0 {
		m.json_object_set(&o, "max", m.float_value(hi))
	}
	return o
}

free_rows :: proc(rows: []m.JSONValue) {
	for row in rows { m.json_destroy(row) }
	m.free_slice(rows)
}
```

## Authentication

```odin
// Bearer token (--auth-token mode)
db := m.connect("http://127.0.0.1:8453", m.Options{token = "my-secret-token"})

// HTTP Basic (--auth-users mode)
db := m.connect("http://127.0.0.1:8453", m.Options{
	username = "admin",
	password = "s3cret",
})
```

A Bearer token takes precedence over Basic credentials when both are supplied. The client guards against CR/LF in credentials to prevent request-smuggling through the auth header.

## Batch transactions

Operations are staged locally on a `Transaction` and committed atomically. The engine enforces unique, foreign-key, and check constraints at commit time.

```odin
txn := m.begin(db)
defer m.free_transaction(&txn)

cells := []m.Cell{{1, m.int_value(10)}, {2, m.string_value("Dave")}}
m.txn_put(&txn, "orders", cells, false)

// atomic - all or nothing. The idempotency key makes it safe to retry.
results, err := m.commit(&txn, "charge-order-123")
	defer free_rows(results)
if err == .Conflict {
	// constraint violated - the engine already rolled back the whole batch.
}
```

## Native query builder

Conditions push down to the engine's specialized indexes. The builder accepts friendly aliases that are translated to the server's on-wire keys: `column` (-> `column_id`), `min`/`max` (-> `lo`/`hi`).

```odin
// Range query (learned-range index).
q := m.query(db, "orders")
defer m.free_query_builder(&q)
cond := m.json_object_make()
defer m.json_object_destroy(cond)
m.json_object_set(&cond, "column", m.int_value(3))
m.json_object_set(&cond, "min", m.float_value(50.0))
m.where_(&q, "range_f64", cond)
m.limit_(&q, 100)
rows, err := m.execute(&q)
for row in rows { m.json_destroy(row) }
m.free_slice(rows)

// Primary-key lookup (the fastest path).
pk := m.query(db, "orders")
defer m.free_query_builder(&pk)
pk_cond := m.json_object_make()
defer m.json_object_destroy(pk_cond)
m.json_object_set(&pk_cond, "value", m.int_value(42))
m.where_(&pk, "pk", pk_cond)
rows2, err2 := m.execute(&pk)
for row in rows2 { m.json_destroy(row) }
m.free_slice(rows2)
```

Query rows come back as `JSONValue` objects, each `{"row_id": ..., "cells": [col_id, value, ...]}`. Walk the flat cells array in pairs to read values by column id.

## SQL

```odin
_, err := m.sql(db, "INSERT INTO orders (id, customer, amount) VALUES (99, 'Zoe', 999.0)")
_, err = m.sql(db, "CREATE TABLE archive AS SELECT * FROM orders WHERE amount > 500")

// Recursive CTEs and window functions
_, err = m.sql(db,
	"WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM r WHERE n<10) SELECT n FROM r")
```

The `/sql` endpoint is requested in JSON format. For statements that yield no rows (DDL/DML) `sql` returns an empty slice with no error.

## Error handling

Every non-2xx response is mapped to a typed error. `switch` on the variant.

```odin
_, err := m.schema_for(db, "missing_table")
switch err {
case .None_:       fmt.println("ok")
case .Not_Found:   fmt.eprintln("not found")
case .Conflict:    fmt.eprintln("constraint violation")
case .Auth:        fmt.eprintln("not authorized")
case:              fmt.eprintf("query/server error: %s\n", m.mongrel_error_string(err))
}
```

| HTTP status | Error |
|-------------|-------|
| 401, 403 | `.Auth` |
| 404 | `.Not_Found` |
| 402, 409 | `.Conflict` |
| 400, other non-2xx | `.Query` |
| 3xx, 5xx | `.Http` |
| transport failure | `.Http` |
| malformed JSON | `.Json` |
| body > 256 MB | `.Response_Too_Large` |
| commit/rollback on a spent transaction | `.Already_Committed` |

## API reference

### `mongreldb`

| Procedure | Description |
|--------|-------------|
| `connect(url, options) -> Client` | Construct a client (url defaults to `http://127.0.0.1:8453`) |
| `health(db) -> (bool, Mongrel_Error)` | Check daemon health |
| `table_names(db) -> ([]string, Mongrel_Error)` | List table names |
| `create_table(db, name, columns) -> (i64, Mongrel_Error)` | Create a table; returns the table id |
| `create_table_with_constraints(db, name, columns, constraints) -> (i64, Mongrel_Error)` | Create a table and attach the top-level engine constraints JSON object |
| `drop_table(db, name) -> Mongrel_Error` | Drop a table |
| `count(db, table) -> (i64, Mongrel_Error)` | Row count |
| `put(db, table, cells, key) -> (JSONValue, Mongrel_Error)` | Insert a row |
| `upsert(db, table, cells, update_cells, key) -> (JSONValue, Mongrel_Error)` | Insert or update on PK conflict |
| `delete(db, table, row_id) -> Mongrel_Error` | Delete by row id |
| `delete_by_pk(db, table, pk) -> Mongrel_Error` | Delete by primary key |
| `query(db, table) -> QueryBuilder` | Start a native query |
| `begin(db) -> Transaction` | Start a batch |
| `sql(db, sql) -> ([]JSONValue, Mongrel_Error)` | Execute SQL |
| `schema(db) -> (map[string]JSONValue, Mongrel_Error)` | Full schema catalog |
| `schema_for(db, table) -> (JSONValue, Mongrel_Error)` | Single-table descriptor |
| `history_retention(db) -> (History_Retention, Mongrel_Error)` | Get the full retention response |
| `history_retention_epochs(db) -> (u64, Mongrel_Error)` | Get the history window size |
| `earliest_retained_epoch(db) -> (u64, Mongrel_Error)` | Get the oldest readable epoch |
| `set_history_retention_epochs(db, epochs) -> (History_Retention, Mongrel_Error)` | Set the history window |

### `QueryBuilder`

| Procedure | Description |
|--------|-------------|
| `where_(qb, type, params) -> ^QueryBuilder` | Add a native condition (AND-ed) |
| `projection(qb, column_ids) -> ^QueryBuilder` | Set column projection |
| `limit_(qb, n) -> ^QueryBuilder` | Set row limit |
| `offset(qb, n) -> ^QueryBuilder` | Skip matching rows before the limit |
| `execute(qb) -> ([]JSONValue, Mongrel_Error)` | Run the query; returns the rows |
| `free_query_builder(qb)` | Release the builder's dynamic storage |

### `Transaction`

| Procedure | Description |
|--------|-------------|
| `txn_put(t, table, cells, returning) -> (^Transaction, Mongrel_Error)` | Stage an insert |
| `txn_delete(t, table, row_id) -> (^Transaction, Mongrel_Error)` | Stage a delete by row id |
| `txn_delete_by_pk(t, table, pk) -> (^Transaction, Mongrel_Error)` | Stage a delete by primary key |
| `txn_count(t) -> int` | Number of staged operations |
| `commit(t, key) -> ([]JSONValue, Mongrel_Error)` | Commit atomically |
| `rollback(t) -> Mongrel_Error` | Discard all operations |
| `free_transaction(t)` | Release the transaction's dynamic storage |

### Value constructors

| Procedure | Description |
|--------|-------------|
| `int_value(i64) -> JSONValue` | Integer cell value |
| `float_value(f64) -> JSONValue` | Float cell value |
| `string_value(string, allocator = context.allocator) -> JSONValue` | String cell value; clones `s` into the allocator so the value owns its storage |
| `bool_value(bool) -> JSONValue` | Boolean cell value |
| `null_value() -> JSONValue` | Null cell value |

> **Strings in JSONValues must be heap-owned.** Never embed a string literal or borrowed slice directly in a `JSONValue` - `json_destroy` would try to free non-heap memory. Use `string_value` (or `m.jstr` inside the library) for any string placed in a value tree.

## Building and testing

Odin has no package manager; the library is the `mongreldb/` directory (the package is declared as `package mongreldb`). Examples and tests import it through a collection named `mdb` that points at the repo root, so `import "mdb:mongreldb"` resolves to the `mongreldb/` directory:

```sh
# Build the library alone (compiles the whole package).
odin build mongreldb -build-mode:lib -vet

# Run the test suite (`odin test` discovers every @(test) proc).
# Live tests self-skip without a daemon; the wire-shape tests always run.
odin test tests -collection:mdb=. -vet

# Build and run an example (each example is its own package; use -file).
odin run examples/basic_crud.odin -file -collection:mdb=. -out:bin/basic_crud
./bin/basic_crud
```

The test suite is a live integration suite: against a running `mongreldb-server` daemon it exercises the full client surface (a 16-operation conformance matrix). It also carries a pure wire-shape test that needs no daemon. Live tests self-skip when no daemon is reachable, so `odin test tests` is safe to run offline.

Fetch a prebuilt server binary from the [MongrelDB releases](https://github.com/visorcraft/MongrelDB/releases):

```sh
mkdir -p bin
curl -fsSL -o bin/mongreldb-server \
  https://github.com/visorcraft/MongrelDB/releases/download/v0.59.1/mongreldb-server-linux-x64
chmod +x bin/mongreldb-server
```

### Using the client in your project

Copy the `mongreldb/` directory (the three `.odin` files) into your project, or add this repo as a git submodule, then point a collection at the directory that *contains* `mongreldb/` so the package resolves:

```sh
git submodule add https://github.com/visorcraft/MongrelDB-Odin.git vendor
# then build with (the collection points at the parent of mongreldb/):
odin build your_app.odin -collection:mdb=vendor
```

In your code, import the package through the collection:

```odin
import m "mdb:mongreldb"
```

## Contributing

Contributions are welcome. Please:

1. Open an issue first for non-trivial changes.
2. Add focused tests near your change - the suite must stay green.
3. Keep the client a thin wrapper over `mongreldb-server`.
4. Match the existing style: tabs for indentation, `snake_case` with a trailing underscore where a name would otherwise clash with a keyword (`where_`, `limit_`).

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the full guide.

## History retention

Control how far back time-travel queries can read. The window is measured in
epochs (monotonically increasing commit numbers).

```odin
window, err := m.history_retention_epochs(db)
if err != .None_ { panic(m.mongrel_error_string(err)) }
fmt.printf("retain %d epochs\n", window)

new_hr, err := m.set_history_retention_epochs(db, 1000)
if err != .None_ { panic(m.mongrel_error_string(err)) }
fmt.printf("window: %d, earliest: %d\n", new_hr.history_retention_epochs, new_hr.earliest_retained_epoch)

// Query an older epoch (use a captured epoch in real code).
earliest, _ := m.earliest_retained_epoch(db)
stmt := fmt.aprintf("SELECT id, amount FROM orders AS OF EPOCH %d", earliest)
defer m.free_string(stmt)
rows, err := m.sql(db, stmt)
if err != .None_ { panic(m.mongrel_error_string(err)) }
for row in rows { m.json_destroy(row) }
m.free_slice(rows)
```

Increasing retention cannot restore epochs that have already been pruned.

## License

Dual-licensed under the **MIT License** or the **Apache License, Version 2.0**,
at your option. See [MIT](LICENSE-MIT) OR [Apache-2.0](LICENSE-APACHE) for the full text.

`SPDX-License-Identifier: MIT OR Apache-2.0`
