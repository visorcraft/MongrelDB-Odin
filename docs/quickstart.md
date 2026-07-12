# Quickstart

Zero to a running MongrelDB Odin program in fifteen minutes. This guide assumes
a fresh machine and walks through installing the prerequisites, starting the
daemon, and writing, running, and understanding a complete program.

---

## 1. Prerequisites

You need two things installed: the Odin compiler and a `mongreldb-server`
daemon.

### Install Odin

MongrelDB Odin is built against a recent Odin dev build. Verify it:

```sh
odin version
# dev-2026-07:... (or newer)
```

If you do not have it, build Odin from source (it bundles its own LLVM):

```sh
git clone https://github.com/odin-lang/Odin.git
cd Odin && ./build_odin.sh release
export PATH="$PWD:$PATH"
```

See <https://odin-lang.org/> for details.

### Install libcurl

The HTTP transport is libcurl, linked via C FFI. On Debian/Ubuntu:

```sh
sudo apt-get install -y libcurl4-openssl-dev
```

On Fedora: `sudo dnf install curl-devel`. On macOS libcurl ships with the
system. Verify the linker can find it:

```sh
curl-config --version
# 8.x ...
```

### Install mongreldb-server

Fetch a prebuilt server binary from the
[MongrelDB releases](https://github.com/visorcraft/MongrelDB/releases):

```sh
mkdir -p bin
curl -fsSL -o bin/mongreldb-server \
  https://github.com/visorcraft/MongrelDB/releases/download/v0.49.0/mongreldb-server-linux-x64
chmod +x bin/mongreldb-server
```

Verify it runs:

```sh
./bin/mongreldb-server --version
```

## 2. Start the daemon

By default `mongreldb-server` listens on `http://127.0.0.1:8453` and stores
data in the directory you pass as its first argument.

```sh
mkdir -p /tmp/mdb-data
./bin/mongreldb-server /tmp/mdb-data
```

In another terminal, sanity-check it:

```sh
curl http://127.0.0.1:8453/health
# ok
```

Leave the daemon running for the rest of this guide.

## 3. Build the client

The library is the `mongreldb/` directory (declared as `package mongreldb`).
Build the whole package directly:

```sh
odin build mongreldb -build-mode:lib -vet
```

Programs that import the client register a collection named `mdb` that points
at the repo root, so `import "mdb:mongreldb"` resolves to the `mongreldb/`
package directory. You pass `-collection:mdb=.` whenever you build a program
that imports the client.

## 4. Write your first program

Create `demo.odin` in the repo root:

```odin
package main

import "core:fmt"
import m "mdb:mongreldb"

main :: proc() {
	// 1. Connect to the daemon. An empty url falls back to
	//    http://127.0.0.1:8453.
	db := m.connect("http://127.0.0.1:8453", m.Options{})

	// 2. Health check before doing anything else.
	ok, err := m.health(db)
	if err != .None_ || !ok {
		fmt.eprintf("daemon not reachable: %s\n", m.mongrel_error_string(err))
		return
	}

	// 3. Create a table. Each column has a stable numeric id, a name, a type,
	//    and flags. The primary_key column is the row identity.
	//
	//    Two optional fields extend the schema:
	//      - has_enum + enum_variants: a fixed set of allowed values for a text
	//        column (server-enforced on commit).
	//      - has_default + default_value: a default applied when a row omits
	//        the column.
	//    Both default to absent and are dropped from the wire JSON when not
	//    set, so the existing schema stays valid.
	status_variants: [dynamic]string
	append(&status_variants, "active")
	append(&status_variants, "inactive")
	append(&status_variants, "paused")
	defer delete(status_variants)

	cols := []m.Column{
		{id = 1, name = "id", ty = "int64", primary_key = true},
		{id = 2, name = "customer", ty = "varchar"},
		{id = 3, name = "amount", ty = "float64"},
		{id = 4, name = "status", ty = "enum",
			has_enum = true, enum_variants = status_variants,
			has_default = true, default_value = "active"},
	}
	tid, cerr := m.create_table(db, "orders", cols)
	if cerr != .None_ {
		fmt.eprintf("create table: %s\n", m.mongrel_error_string(cerr))
		return
	}
	fmt.printf("created table id: %lld\n", tid)

	// 4. Insert rows. Cells pair column id + value. The status column is
	//    constrained to {"active","inactive","paused"}.
	r1 := []m.Cell{
		{1, m.int_value(1)},
		{2, m.string_value("Alice")},
		{3, m.float_value(99.5)},
		{4, m.string_value("active")},
	}
	pres, perr := m.put(db, "orders", r1, "")
	defer m.json_destroy(pres)
	if perr != .None_ {
		fmt.eprintf("put: %s\n", m.mongrel_error_string(perr))
		return
	}

	// 5. Query with a native index condition. The range index serves this in
	//    sub-millisecond.
	cond := m.json_object_make()
	defer m.json_object_destroy(cond)
	m.json_object_set(&cond, "column", m.int_value(3))
	m.json_object_set(&cond, "min", m.float_value(50.0))
	qb := m.query(db, "orders")
	defer m.free_query_builder(&qb)
	m.where_(&qb, "range_f64", cond)
	rows, qerr := m.execute(&qb)
	defer free_rows(rows)
	if qerr != .None_ {
		fmt.eprintf("query: %s\n", m.mongrel_error_string(qerr))
		return
	}
	fmt.printf("query returned %d rows\n", len(rows))

	// 6. Count the rows.
	n, _ := m.count(db, "orders")
	fmt.printf("total rows: %lld\n", n)

	// 7. Read and optionally adjust the history retention window.
	window, err := m.history_retention_epochs(db)
	if err != .None_ {
		fmt.eprintf("history retention: %s\n", m.mongrel_error_string(err))
		return
	}
	fmt.printf("history retention epochs: %d\n", window)
}

free_rows :: proc(rows: []m.JSONValue) {
	for row in rows { m.json_destroy(row) }
	m.free_slice(rows)
}
```

Build and run it:

```sh
odin run demo.odin -file -collection:mdb=. -out:demo
./demo
```

You should see a row count of 1.

## 5. What each part does

| Code | What it does |
|------|--------------|
| `connect(url, options)` | Builds an HTTP client targeting one daemon. The `Client` is a value type carrying the base URL and credentials. |
| `health(db)` | GET `/health`; returns `(true, .None_)` when the daemon answers. Always check before real work. |
| `create_table(db, name, cols)` | POST `/kit/create_table`. Column `id`s are the on-wire identifiers; use them everywhere else. |
| `create_table_with_constraints(db, name, cols, constraints)` | Same request with a top-level engine constraints JSON object, such as `checks`. |
| `col.has_enum / enum_variants` | Optional. Constrains a text column to a fixed value set; server-enforced on commit, surfaces as `.Conflict` on a row outside the set. Absent when `has_enum` is false. |
| `col.has_default / default_value` | Optional string default. The server's `default_expr` field name is also accepted. |
| `col.has_default_scalar / default_scalar` | Optional JSON scalar default for numeric, boolean, or null values. Sent as `default_value`. |
| `col.has_default_expr / default_expr` | Dynamic `now` or `uuid` default. Takes precedence over scalar and string defaults. |
| `put(db, table, cells, key)` | Single-op transaction: POST `/kit/txn` with one `put` op. `cells` is flattened to `[col_id, val, ...]`. |
| `query(db, table) + where_` | Builds a `/kit/query` body. Conditions push down to native indexes. |
| `count(db, table)` | GET `/tables/{name}/count`. |

## 6. Constrained columns

`Column` accepts two optional constraint-style fields that are forwarded to the
daemon verbatim. They are omitted from the JSON body when not set, so existing
schemas that don't set them produce an identical payload.

| Field | Type | Effect |
|-------|------|--------|
| `has_enum` + `enum_variants` | `bool` + `[dynamic]string` | Restrict the column to one of the listed string values. The engine rejects writes outside the set with `.Conflict`. |
| `has_default` + `default_value` | `bool` + `string` | String default applied when the cell is omitted on a `put`. |
| `has_default_scalar` + `default_scalar` | `bool` + `JSONValue` | Non-string JSON scalar default. Caller must supply the scalar type expected by the column. Takes precedence over `default_value`. |
| `has_default_expr` + `default_expr` | `bool` + `string` | Dynamic `now` or `uuid`. Takes precedence over both static fields. |

Both fields compose. A column can be a plain string, an enum-only string, a
string with a default, or an enum with a default:

```odin
// Plain string - no constraints, no extra keys on the wire.
{id = 2, name = "customer", ty = "varchar"},

// Enum only - writes outside the set are rejected at commit time.
{id = 4, name = "status", ty = "varchar",
   has_enum = true, enum_variants = status_variants},

// Enum with a default - the engine fills in "active" when the cell is omitted.
{id = 5, name = "currency", ty = "varchar",
   has_enum = true, enum_variants = currency_variants,
   has_default = true, default_value = "USD"},
```

An empty `enum_variants` is also omitted, so `has_enum = false` and
`has_enum = true` with an empty dynamic array produce identical wire shapes.

## 7. Common pitfalls

**Using the column name instead of the column id.** Every on-wire API uses the
numeric `id` from `create_table`, never the `name`. Conditions take the int64
`column` (rewritten to `column_id`), not the string name:

```odin
// Wrong:
m.json_object_set(&cond, "column", m.string_value("amount"))
// Right:
m.json_object_set(&cond, "column", m.int_value(3))
```

**Forgetting to free a builder or transaction.** A `QueryBuilder` and a
`Transaction` hold dynamic allocations. Call `free_query_builder(&qb)` /
`free_transaction(&t)` (a `defer` is the idiomatic place) to release them.
Result slices returned by `execute` / `commit` / `sql` are owned by the caller
until their owning JSON value is destroyed.

**Treating a single `put` as non-transactional.** `put` is a one-op
transaction. A unique constraint violation surfaces as `.Conflict` (HTTP 409),
not as a silent no-op.

**Calling `commit` twice on the same `Transaction`.** The second call returns
`.Already_Committed`. Create a fresh `begin(db)` for each logical unit of work.

**Embedding borrowed strings in a `JSONValue`.** Strings inside a `JSONValue`
must be heap-owned - `json_destroy` frees them. Always build cell values with
`string_value` (which clones), never by wrapping a literal or borrowed slice.

**Expecting `sql` to always return rows.** The `/sql` endpoint returns a JSON
array for `SELECT` when the server honors the JSON format, but for DDL/DML it
returns an empty slice. Use the native query builder for typed row retrieval,
and SQL for DDL/DML/admin.

**Pointing at a daemon that requires auth.** If the daemon was started with
`--auth-token` or `--auth-users`, every call fails with `.Auth` unless you set
`Options.token` or `Options.username`/`Options.password`. See [auth.md](auth.md).

**Assuming `enum_variants` is checked client-side.** The Odin client only emits
the constraint in the wire JSON; the engine enforces it on `put` / `commit` and
returns `.Conflict` for any value outside the set. Validate at the edge if you
need faster feedback.

## Next steps

- [transactions.md](transactions.md) - atomic batches, idempotency, retries
- [queries.md](queries.md) - every native index condition
- [sql.md](sql.md) - recursive CTEs, window functions, `CREATE TABLE AS SELECT`
- [auth.md](auth.md) - bearer tokens, basic auth, user/role management
- [errors.md](errors.md) - the full error set and recovery patterns
