# Queries

The `query` + `where_` builder pushes conditions down to MongrelDB's native
indexes for sub-millisecond lookups - primary key, learned-range, bitmap,
full-text, and more. Each condition type maps to one specialized index;
conditions are AND-ed together.

```odin
cond := mongreldb.json_object_make()
mongreldb.json_object_set(&cond, "column", mongreldb.int_value(3))
mongreldb.json_object_set(&cond, "min", mongreldb.float_value(100.0))
mongreldb.json_object_set(&cond, "max", mongreldb.float_value(500.0))

mut qb := db.query("orders")
defer mongreldb.free_query_builder(&qb)
qb.where_("range_f64", cond)
qb.projection({1, 2})
qb.limit_(100)
rows, err := qb.execute()
```

This guide covers every condition type, projection, limits, combining
conditions, and how to read the returned rows.

---

## The basics

A `QueryBuilder` accumulates a single table query. Start one with `query`,
append zero or more conditions with `where_`, optionally set a projection and a
limit, then call `execute`:

```odin
mut qb := db.query("orders")
defer mongreldb.free_query_builder(&qb)
qb.where_(...)
qb.limit_(100)
rows, err := qb.execute()
```

The request body the builder produces matches the daemon's `/kit/query` shape:

```json
{
  "table": "orders",
  "conditions": [{"range": {"column_id": 3, "lo": 100.0, "hi": 500.0}}],
  "projection": [1, 2],
  "limit": 100
}
```

`free_query_builder(&qb)` releases the builder's dynamic storage. The returned
`rows` slice (`[]JSONValue`) is owned by the caller until its owning JSON value
is destroyed.

## Reading rows

Each returned row is a `JSONValue` object of the form
`{"row_id": "...", "cells": [col_id, value, col_id, value, ...]}`. The `cells`
array is flat: walk it in pairs to read values by column id.

```odin
for row in rows {
	obj, ok := row.(mongreldb.JSONObject)
	if !ok do continue
	cells_any, has := mongreldb.json_object_get(obj, "cells")
	if !has do continue
	cells, ok := cells_any.(mongreldb.JSONArray)
	if !ok do continue

	// Walk cells in [col_id, value] pairs.
	i := 0
	for i + 1 < len(cells) {
		col_id, _ := cells[i].(mongreldb.JSONInteger)
		value := cells[i + 1]
		switch v in value {
		case mongreldb.JSONInteger: fmt.printf("col %lld = %lld\n", col_id, v)
		case mongreldb.JSONFloat:   fmt.printf("col %lld = %g\n",   col_id, v)
		case mongreldb.JSONString:  fmt.printf("col %lld = %s\n",  col_id, v)
		case:                       fmt.printf("col %lld = ...\n", col_id)
		}
		i += 2
	}
}
```

## Condition types

A condition is built as a `JSONObject` of params and passed to `where_` with a
condition type string. Friendly param aliases are rewritten to the server's
canonical fields:

| Alias (you pass) | Canonical (on-wire) |
|------------------|---------------------|
| `column` | `column_id` |
| `min` | `lo` |
| `max` | `hi` |
| `min_inclusive` | `lo_inclusive` |
| `max_inclusive` | `hi_inclusive` |
| `value` (for `fm_contains`/`fm_contains_all`) | `pattern` |

Column references use the numeric **column id**, never the column name.

### `pk` - exact primary-key match

The fastest lookup. Supply the primary-key value as `value`.

```odin
cond := mongreldb.json_object_make()
mongreldb.json_object_set(&cond, "value", mongreldb.int_value(42))
qb.where_("pk", cond)
```

For a string PK, pass a `JSONString`:

```odin
mongreldb.json_object_set(&cond, "value", mongreldb.string_value("user-42"))
```

### `range` / `range_f64` - numeric range (learned-range index)

Use `range` for integer columns and `range_f64` for float columns. Both bounds
default to inclusive.

```odin
cond := mongreldb.json_object_make()
mongreldb.json_object_set(&cond, "column", mongreldb.int_value(3))
mongreldb.json_object_set(&cond, "min", mongreldb.float_value(100.0))
mongreldb.json_object_set(&cond, "max", mongreldb.float_value(500.0))
qb.where_("range_f64", cond)

// Open-ended: amount >= 100 (no max).
open_cond := mongreldb.json_object_make()
mongreldb.json_object_set(&open_cond, "column", mongreldb.int_value(3))
mongreldb.json_object_set(&open_cond, "min", mongreldb.float_value(100.0))
qb.where_("range_f64", open_cond)
```

To control inclusivity, pass `min_inclusive` / `max_inclusive` booleans.

### `bitmap_eq` - equality on a bitmap-indexed column

Best for low-cardinality columns (status, category, booleans).

```odin
cond := mongreldb.json_object_make()
mongreldb.json_object_set(&cond, "column", mongreldb.int_value(2))
mongreldb.json_object_set(&cond, "value", mongreldb.string_value("Alice"))
qb.where_("bitmap_eq", cond)
```

### `is_null` / `is_not_null` - null checks

```odin
is_null := mongreldb.json_object_make()
mongreldb.json_object_set(&is_null, "column", mongreldb.int_value(3))
qb.where_("is_null", is_null)

not_null := mongreldb.json_object_make()
mongreldb.json_object_set(&not_null, "column", mongreldb.int_value(3))
qb.where_("is_not_null", not_null)
```

### `fm_contains` / `fm_contains_all` - full-text substring (FM-index)

Substring match within a column. The `value` alias is rewritten to the on-wire
`pattern`.

```odin
cond := mongreldb.json_object_make()
mongreldb.json_object_set(&cond, "column", mongreldb.int_value(2))
mongreldb.json_object_set(&cond, "value", mongreldb.string_value("database performance"))
qb.where_("fm_contains", cond)
```

`fm_contains_all` requires every space-separated term to match; `fm_contains`
matches any. For vector similarity (`ann`), sparse match, and MinHash
similarity, use SQL or extend the condition type string - the server supports
them on the wire; this client covers the most common index conditions. See
[sql.md](sql.md).

## Projection (column selection)

Pass a column-id array to `projection` to restrict the columns in each returned
row. Projecting to only the columns you need cuts bandwidth and decode cost.

```odin
qb.projection({1, 2}) // id and customer only
```

## Limit

A non-zero `limit_` caps the result. (The daemon also reports a `truncated`
flag in the raw response when more matches exist; the client surfaces rows
only - check `len(rows)` against your limit to detect overflow.)

```odin
qb.limit_(100)
rows, _ := qb.execute()
if len(rows) == 100 {
	// Possibly more rows exist on the server; raise the limit or page with a
	// range predicate on the PK.
}
```

## Multiple AND conditions

Call `where_` more than once. Every condition must match; the server intersects
the index results.

```odin
// Customer is Alice AND amount is between 100 and 500.
b := mongreldb.json_object_make()
mongreldb.json_object_set(&b, "column", mongreldb.int_value(2))
mongreldb.json_object_set(&b, "value", mongreldb.string_value("Alice"))
qb.where_("bitmap_eq", b)

r := mongreldb.json_object_make()
mongreldb.json_object_set(&r, "column", mongreldb.int_value(3))
mongreldb.json_object_set(&r, "min", mongreldb.float_value(100.0))
mongreldb.json_object_set(&r, "max", mongreldb.float_value(500.0))
qb.where_("range_f64", r)
```

Because each condition targets a different specialized index, the engine can
pick the most selective one to drive the lookup and intersect the rest.

## Putting it together

A realistic combined lookup - bitmap equality + range + projection + limit:

```odin
top_spenders :: proc(db: mongreldb.Client, table, customer: string) {
	mut qb := db.query(table)
	defer mongreldb.free_query_builder(&qb)

	b := mongreldb.json_object_make()
	mongreldb.json_object_set(&b, "column", mongreldb.int_value(2))
	mongreldb.json_object_set(&b, "value", mongreldb.string_value(customer))
	qb.where_("bitmap_eq", b)

	r := mongreldb.json_object_make()
	mongreldb.json_object_set(&r, "column", mongreldb.int_value(3))
	mongreldb.json_object_set(&r, "min", mongreldb.float_value(100.0))
	qb.where_("range_f64", r)

	qb.projection({1, 3})
	qb.limit_(50)

	rows, err := qb.execute()
	if err != .None_ do return
	_ = rows
	// ... read rows ...
}
```

For arbitrary predicates, joins, and aggregations that the native indexes do
not cover, use SQL instead - see [sql.md](sql.md).
