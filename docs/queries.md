# Queries

The `query` + `where_` builder pushes conditions down to MongrelDB's native
indexes for sub-millisecond lookups - primary key, learned-range, bitmap,
full-text, and more. Each condition type maps to one specialized index;
conditions are AND-ed together.

```odin
import m "mdb:mongreldb"

cond := m.json_object_make()
m.json_object_set(&cond, "column", m.int_value(3))
m.json_object_set(&cond, "min", m.float_value(100.0))
m.json_object_set(&cond, "max", m.float_value(500.0))

qb := m.query(db, "orders")
defer m.free_query_builder(&qb)
m.where_(&qb, "range_f64", cond)
m.projection(&qb, {1, 2})
m.limit_(&qb, 100)
rows, err := m.execute(&qb)
```

This guide covers every condition type, projection, limits, combining
conditions, and how to read the returned rows.

---

## The basics

A `QueryBuilder` accumulates a single table query. Start one with `query`,
append zero or more conditions with `where_`, optionally set a projection and a
limit, then call `execute`:

```odin
qb := m.query(db, "orders")
defer m.free_query_builder(&qb)
m.where_(&qb, ...)
m.limit_(&qb, 100)
rows, err := m.execute(&qb)
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
	obj, ok := row.(m.JSONObject)
	if !ok do continue
	cells_any, has := m.json_object_get(obj, "cells")
	if !has do continue
	cells, ok := cells_any.(m.JSONArray)
	if !ok do continue

	// Walk cells in [col_id, value] pairs.
	i := 0
	for i + 1 < len(cells) {
		col_id, _ := cells[i].(m.JSONInteger)
		value := cells[i + 1]
		switch v in value {
		case m.JSONInteger: fmt.printf("col %lld = %lld\n", col_id, v)
		case m.JSONFloat:   fmt.printf("col %lld = %g\n",   col_id, v)
		case m.JSONString:  fmt.printf("col %lld = %s\n",  col_id, v)
		case:               fmt.printf("col %lld = ...\n", col_id)
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
cond := m.json_object_make()
m.json_object_set(&cond, "value", m.int_value(42))
m.where_(&qb, "pk", cond)
```

For a string PK, pass a `JSONString`:

```odin
m.json_object_set(&cond, "value", m.string_value("user-42"))
```

### `range` / `range_f64` - numeric range (learned-range index)

Use `range` for integer columns and `range_f64` for float columns. Both bounds
default to inclusive.

```odin
cond := m.json_object_make()
m.json_object_set(&cond, "column", m.int_value(3))
m.json_object_set(&cond, "min", m.float_value(100.0))
m.json_object_set(&cond, "max", m.float_value(500.0))
m.where_(&qb, "range_f64", cond)

// Open-ended: amount >= 100 (no max).
open_cond := m.json_object_make()
m.json_object_set(&open_cond, "column", m.int_value(3))
m.json_object_set(&open_cond, "min", m.float_value(100.0))
m.where_(&qb, "range_f64", open_cond)
```

To control inclusivity, pass `min_inclusive` / `max_inclusive` booleans.

### `bitmap_eq` - equality on a bitmap-indexed column

Best for low-cardinality columns (status, category, booleans).

```odin
cond := m.json_object_make()
m.json_object_set(&cond, "column", m.int_value(2))
m.json_object_set(&cond, "value", m.string_value("Alice"))
m.where_(&qb, "bitmap_eq", cond)
```

### `is_null` / `is_not_null` - null checks

```odin
is_null := m.json_object_make()
m.json_object_set(&is_null, "column", m.int_value(3))
m.where_(&qb, "is_null", is_null)

not_null := m.json_object_make()
m.json_object_set(&not_null, "column", m.int_value(3))
m.where_(&qb, "is_not_null", not_null)
```

### `fm_contains` / `fm_contains_all` - full-text substring (FM-index)

Substring match within a column. The `value` alias is rewritten to the on-wire
`pattern`.

```odin
cond := m.json_object_make()
m.json_object_set(&cond, "column", m.int_value(2))
m.json_object_set(&cond, "value", m.string_value("database performance"))
m.where_(&qb, "fm_contains", cond)
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
m.projection(&qb, {1, 2}) // id and customer only
```

## Limit

A non-zero `limit_` caps the result. (The daemon also reports a `truncated`
flag in the raw response when more matches exist; the client surfaces rows
only - check `len(rows)` against your limit to detect overflow.)

```odin
m.limit_(&qb, 100)
rows, _ := m.execute(&qb)
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
b := m.json_object_make()
m.json_object_set(&b, "column", m.int_value(2))
m.json_object_set(&b, "value", m.string_value("Alice"))
m.where_(&qb, "bitmap_eq", b)

r := m.json_object_make()
m.json_object_set(&r, "column", m.int_value(3))
m.json_object_set(&r, "min", m.float_value(100.0))
m.json_object_set(&r, "max", m.float_value(500.0))
m.where_(&qb, "range_f64", r)
```

Because each condition targets a different specialized index, the engine can
pick the most selective one to drive the lookup and intersect the rest.

## Putting it together

A realistic combined lookup - bitmap equality + range + projection + limit:

```odin
top_spenders :: proc(db: m.Client, table, customer: string) {
	qb := m.query(db, table)
	defer m.free_query_builder(&qb)

	b := m.json_object_make()
	m.json_object_set(&b, "column", m.int_value(2))
	m.json_object_set(&b, "value", m.string_value(customer))
	m.where_(&qb, "bitmap_eq", b)

	r := m.json_object_make()
	m.json_object_set(&r, "column", m.int_value(3))
	m.json_object_set(&r, "min", m.float_value(100.0))
	m.where_(&qb, "range_f64", r)

	m.projection(&qb, {1, 3})
	m.limit_(&qb, 50)

	rows, err := m.execute(&qb)
	if err != .None_ do return
	_ = rows
	// ... read rows ...
}
```

For arbitrary predicates, joins, and aggregations that the native indexes do
not cover, use SQL instead - see [sql.md](sql.md).
