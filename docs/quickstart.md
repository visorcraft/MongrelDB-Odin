# Quickstart

Zero to a running MongrelDB Odin program in fifteen minutes. This guide assumes
a fresh machine and walks through installing the prerequisites, starting the
daemon, and writing, running, and understanding a complete program.

---

## 1. Prerequisites

You need three things installed: Odin, libcurl (with headers), and a
`mongreldb-server` daemon.

### Install Odin and libcurl

Odin is built from source (it tracks a moving dev branch). Clone and build it:

```sh
git clone --depth 1 https://github.com/odin-lang/Odin.git
cd Odin && ./build_odin.sh release
# Add the Odin binary to your PATH (or invoke it directly as ./odin).
```

On Debian/Ubuntu install libcurl:

```sh
sudo apt install libcurl4-openssl-dev
```

On Fedora:

```sh
sudo dnf install libcurl-devel
```

Verify:

```sh
odin version
pkg-config --modversion libcurl   # 8.x
```

### Install mongreldb-server

Fetch a prebuilt server binary from the
[MongrelDB releases](https://github.com/visorcraft/MongrelDB/releases):

```sh
mkdir -p bin
curl -fsSL -o bin/mongreldb-server \
  https://github.com/visorcraft/MongrelDB/releases/download/v0.46.2/mongreldb-server-linux-x64
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
/path/to/mongreldb-server /tmp/mdb-data
```

In another terminal, sanity-check it:

```sh
curl http://127.0.0.1:8453/health
# ok
```

Leave the daemon running for the rest of this guide.

## 3. Build the client

The client is a set of source files in `src/`. Build the whole package by
pointing `odin build` at any file in the collection:

```sh
odin build src/mongreldb.odin -collection:mongreldb=src -vet
```

The `-collection:mongreldb=src` flag registers a collection named `mongreldb`
that resolves `import "mongreldb"` to the library sources. You pass this same
flag whenever you build a program that imports the client.

## 4. Write your first program

Create `demo.odin`:

```odin
package main

import "core:fmt"
import mongreldb "mongreldb"

main :: proc() {
	// 1. Connect to the daemon. An empty url falls back to
	//    http://127.0.0.1:8453.
	db := mongreldb.connect("http://127.0.0.1:8453", mongreldb.Options{})

	// 2. Health check before doing anything else.
	ok, err := db.health()
	if err != .None_ || !ok {
		fmt.eprintf("daemon not reachable: %s\n", mongreldb.mongrel_error_string(err))
		return
	}

	// 3. Create a table. Each column has a stable numeric id, a name, a type,
	//    and flags. The first column is the primary key.
	//
	//    Two optional fields extend the schema:
	//      - has_enum + enum_variants: a fixed set of allowed values for a text
	//        column (server-enforced on commit).
	//      - has_default + default_value: a default applied when a row omits
	//        the column.
	//    Both default to absent and are dropped from the wire JSON when not
	//    set, so the existing schema stays valid.
	status_variants := make([dynamic]string)
	defer delete(status_variants)
	append(&status_variants, "active")
	append(&status_variants, "inactive")
	append(&status_variants, "paused")

	cols := []mongreldb.Column{
		{id = 1, name = "id", ty = "int64", primary_key = true},
		{id = 2, name = "customer", ty = "varchar"},
		{id = 3, name = "amount", ty = "float64"},
		{id = 4, name = "status", ty = "varchar",
			has_enum = true, enum_variants = status_variants,
			has_default = true, default_value = "active"},
	}
	tid, cerr := db.create_table("orders", cols)
	if cerr != .None_ {
		fmt.eprintf("create table: %s\n", mongreldb.mongrel_error_string(cerr))
		return
	}

	// 4. Insert rows. Cells pair column id + value. The status column is
	//    constrained to {"active","inactive","paused"}.
	r1 := []mongreldb.Cell{
		{1, mongreldb.int_value(1)},
		{2, mongreldb.string_value("Alice")},
		{3, mongreldb.float_value(99.5)},
		{4, mongreldb.string_value("active")},
	}
	_, perr := db.put("orders", r1, "")
	if perr != .None_ {
		fmt.eprintf("put: %s\n", mongreldb.mongrel_error_string(perr))
		return
	}

	// 5. Query with a native index condition. The range index serves this in
	//    sub-millisecond.
	cond := mongreldb.json_object_make()
	mongreldb.json_object_set(&cond, "column", mongreldb.int_value(3))
	mongreldb.json_object_set(&cond, "min", mongreldb.float_value(50.0))
	mut qb := db.query("orders")
	defer mongreldb.free_query_builder(&qb)
	qb.where_("range_f64", cond)
	rows, qerr := qb.execute()
	if qerr != .None_ {
		fmt.eprintf("query: %s\n", mongreldb.mongrel_error_string(qerr))
		return
	}
	fmt.printf("query returned %d rows\n", len(rows))

	// 6. Count the rows.
	n, _ := db.count("orders")
	fmt.printf("total rows: %lld\n", n)
}
```

Build and run it:

```sh
odin run demo.odin -collection:mongreldb=src -out:demo
./demo
```

You should see the row count of 1.

## 5. What each part does

| Code | What it does |
|------|--------------|
| `connect(url, options)` | Builds an HTTP client targeting one daemon. The `Client` is a value type; pass it by value (it carries no resources to close). |
| `health(db)` | GET `/health`; returns `.None_` when the daemon answers. Always check before real work. |
| `create_table(db, name, cols)` | POST `/kit/create_table`. Column `id`s are the on-wire identifiers; use them everywhere else. |
| `col.has_enum / enum_variants` | Optional. Constrains a text column to a fixed value set; server-enforced on commit, surfaces as `.Conflict` on a row outside the set. Absent when `has_enum` is false. |
| `col.has_default / default_value` | Optional. Default value string for the column. Absent when `has_default` is false. The server's `default_expr` field name is also accepted. |
| `put(db, table, cells, key)` | Single-op transaction: POST `/kit/txn` with one `put` op. `cells` is flattened to `[col_id, val, ...]`. |
| `query(db, table) + where_` | Builds a `/kit/query` body. Conditions push down to native indexes. |
| `count(db, table)` | GET `/tables/{name}/count`. |

## 6. Common pitfalls

**Using the column name instead of the column id.** Every on-wire API uses the
numeric `id` from `create_table`, never the `name`. Conditions take the int64
`column` (rewritten to `column_id`), not the string name.

**Forgetting to free a builder or transaction.** A `QueryBuilder` and a
`Transaction` hold dynamic allocations. Call `free_query_builder(&qb)` /
`free_transaction(&t)` (a `defer` is the idiomatic place) to release them.
Result slices returned by `execute` / `commit` / `sql` are owned by the caller
until their owning JSON value is destroyed.

**Treating a single `put` as non-transactional.** `put` is a one-op
transaction. A unique constraint violation surfaces as `.Conflict` (HTTP 409),
not as a silent no-op.

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
