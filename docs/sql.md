# SQL

MongrelDB ships a DataFusion-backed SQL engine at `POST /sql`. From Odin, run
SQL with `sql`:

```odin
rows, err := db.sql("SELECT 1")
```

This guide covers the SQL surface - DDL, DML, `CREATE TABLE AS SELECT`,
recursive CTEs, and window functions - and when to reach for SQL versus the
native query builder.

---

## How `sql` behaves

`sql(db, sql_text)` sends `{"sql": "...", "format": "json"}` to `/sql`. It
returns `.None_` on a 2xx response.

In practice:

- **DDL and DML** (`CREATE TABLE`, `INSERT`, `UPDATE`, `DELETE`) reply with a
  non-JSON status body. `sql` returns `.None_` with an empty slice - success is
  the signal.
- **`SELECT`** in daemon builds that honor the requested JSON format returns a
  JSON array of row objects keyed by column name, decoded into the returned
  `[]JSONValue`. In older builds the server streams Arrow IPC bytes rather than
  JSON; `sql` detects a non-array body and returns an empty slice rather than a
  `.Json` error. Use the native query builder for typed row retrieval in
  application code, and SQL for statements whose execution is the goal.

Errors are mapped to the same `Mongrel_Error` values as everything else: an HTTP
400 or 5xx is `.Query`/`.Http`; 409 is `.Conflict`; and so on. See
[errors.md](errors.md).

```odin
_, err := db.sql(
	"INSERT INTO orders (id, customer, amount) VALUES (99, 'Zoe', 999.0)")
if err == .Conflict {
	fmt.eprintln("duplicate row")
}
```

## CREATE TABLE

Define a table in SQL instead of via `create_table`. Column ids are assigned by
the server when not stated.

```odin
_, _ = db.sql(
	"CREATE TABLE products (" +
	"  id INT64 PRIMARY KEY," +
	"  name VARCHAR," +
	"  price FLOAT64," +
	"  category VARCHAR," +
	"  in_stock BOOLEAN)")
```

## INSERT

```odin
_, _ = db.sql(
	"INSERT INTO products (id, name, price, category, in_stock) " +
	"VALUES (1, 'Widget', 9.99, 'tools', true)")
_, _ = db.sql(
	"INSERT INTO products VALUES (2, 'Gadget', 19.99, 'tools', true)")
```

For bulk inserts, the native batch transaction (`commit`) is usually faster
because it stages ops in one round trip without re-parsing SQL.

## UPDATE

```odin
_, _ = db.sql("UPDATE products SET price = 14.99 WHERE id = 1")
_, _ = db.sql("UPDATE orders SET amount = 200.0 WHERE customer = 'Bob'")
```

## DELETE

```odin
_, _ = db.sql("DELETE FROM products WHERE in_stock = false")
_, _ = db.sql("DELETE FROM products WHERE id = 2")
```

## SELECT

```odin
rows, _ := db.sql("SELECT id, name FROM products WHERE category = 'tools' ORDER BY price")
rows, _ = db.sql("SELECT category, COUNT(*) AS n FROM products GROUP BY category")
```

Each returned row is a `JSONValue` object keyed by column name. Read a field
with `json_object_get`:

```odin
for row in rows {
	obj, ok := row.(mongreldb.JSONObject)
	if !ok do continue
	name_any, has := mongreldb.json_object_get(obj, "name")
	if has {
		name, _ := name_any.(mongreldb.JSONString)
		fmt.printf("name = %s\n", name)
	}
}
```

Remember SELECT bodies may arrive as Arrow IPC on older servers, in which case
`sql` returns an empty slice. To read rows back into typed values reliably,
mirror the same lookup with the native query builder.

## CREATE TABLE AS SELECT

Materialize a query result into a new table. Great for snapshots, rollups, and
denormalized aggregates.

```odin
// Snapshot all high-value orders into a new table.
_, _ = db.sql("CREATE TABLE archive AS SELECT * FROM orders WHERE amount > 500")

// Roll up sales by customer.
_, _ = db.sql(
	"CREATE TABLE sales_by_customer AS " +
	"SELECT customer, SUM(amount) AS total FROM orders GROUP BY customer")
```

The new table inherits column types from the query. Query it afterward with the
native builder or SQL.

## Recursive CTEs

`WITH RECURSIVE` is fully supported. Classic use cases: series generation,
hierarchy/graph traversal.

```odin
// Generate the numbers 1..10.
_, _ = db.sql(
	"WITH RECURSIVE r(n) AS (" +
	"  SELECT 1 UNION ALL SELECT n + 1 FROM r WHERE n < 10" +
	") SELECT n FROM r")
```

A common practical example is walking an adjacency list:

```odin
_, _ = db.sql(
	"WITH RECURSIVE descendants(id) AS (" +
	"  SELECT id FROM categories WHERE id = 1" +
	"  UNION ALL" +
	"  SELECT c.id FROM categories c JOIN descendants d ON c.parent_id = d.id" +
	") SELECT id FROM descendants")
```

## Window functions

Window functions compute aggregates/rankings across a moving window without
collapsing rows. Useful for top-N-per-group, running totals, and row numbers.

```odin
// Row number within each customer, ordered by amount descending.
_, _ = db.sql(
	"SELECT id, customer, amount, " +
	"ROW_NUMBER() OVER (PARTITION BY customer ORDER BY amount DESC) AS rn " +
	"FROM orders")

// Running total per customer.
_, _ = db.sql(
	"SELECT id, customer, amount, " +
	"SUM(amount) OVER (PARTITION BY customer ORDER BY id) AS running_total " +
	"FROM orders")
```

`RANK()`, `DENSE_RANK()`, `LAG()`, `LEAD()`, `NTILE()`, and the usual
window-frame clauses are available through DataFusion.

## When to use SQL vs. the query builder

Both read from the same tables, but they are optimized for different jobs.

| Reach for | When |
|-----------|------|
| **query builder** | Point lookups, range scans, bitmap filters, and full-text that map to a native index. Sub-millisecond, no parser overhead, and rows decode into typed values directly. |
| **SQL** | DDL (`CREATE TABLE`, schemas, materialized views), multi-statement setup, joins, recursive CTEs, window functions, and arbitrary aggregates. Also the natural choice for admin scripts and one-off analysis. |

Rules of thumb:

- Need typed rows of matching values? Use the query builder.
- Building/dropping tables, or running a `CREATE TABLE AS SELECT`? Use SQL.
- Joining multiple tables, computing rankings, or walking a graph? Use SQL.
- Filtering by one or more indexed columns? Use the query builder - it is
  faster and avoids Arrow-to-typed decoding.

Mix freely: create tables with SQL, write rows with `put`, read them back with
the query builder, and run analytics with SQL.

## Next steps

- [queries.md](queries.md) - every native index condition in detail
- [transactions.md](transactions.md) - bulk inserts via batch transactions
- [errors.md](errors.md) - handling SQL execution errors
