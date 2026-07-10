# Transactions

MongrelDB commits every write through a single atomic transaction endpoint
(`POST /kit/txn`). This guide covers the two ways to use it - a one-shot single
op, and a staged batch - plus idempotency keys for safe retries and
constraint-violation handling.

The engine enforces `UNIQUE`, foreign-key, check, and trigger constraints at
**commit time**. A violation aborts the entire batch: no op in the batch
becomes visible.

---

## Single puts vs. batch transactions

### Single op: `put`

`put` is a convenience wrapper that sends a one-op transaction. Use it when a
write is independent and you do not need atomicity across multiple rows.

```odin
import m "mdb:mongreldb"

r := []m.Cell{
	{1, m.int_value(1)},
	{2, m.string_value("Alice")},
	{3, m.float_value(99.5)},
}
_, err := m.put(db, "orders", r, "" /* no idempotency key */)
if err != .None_ {
	fmt.eprintf("put failed: %s\n", m.mongrel_error_string(err))
}
```

`upsert`, `delete`, and `delete_by_pk` are the same shape: single-op
transactions.

### Batch: `begin` + `commit`

When several writes must succeed or fail together, stage them on a
`Transaction` and commit once. All ops go to the server in a single HTTP
request and commit atomically.

```odin
a := make([dynamic]m.Cell, 2)
a[0] = {1, m.int_value(10)}
a[1] = {2, m.string_value("Dave")}

txn := m.begin(db)
defer m.free_transaction(&txn)
_, perr := m.txn_put(&txn, "orders", a[:], false)
if perr != .None_ { /* ... */ }

results, err := m.commit(&txn, "")
```

Each `txn_*` helper appends one op and returns `(^Transaction, Mongrel_Error)`
so you can check or chain:

```odin
txn := m.begin(db)
defer m.free_transaction(&txn)
m.txn_put(&txn, "orders", cells_a[:], false)
m.txn_put(&txn, "orders", cells_b[:], false)
m.txn_delete_by_pk(&txn, "orders", m.int_value(2))
results, err := m.commit(&txn, "")
```

`txn_count` returns the number of staged operations (handy for asserts):

```odin
if m.txn_count(&txn) != 3 { panic("expected 3 ops") }
```

## Idempotency keys for safe retries

Networks drop requests and daemons crash after committing but before replying.
An idempotency key makes a commit safe to retry: the daemon remembers the key
and replays the **original** result on a duplicate commit, even across
restarts.

Pass the key as the last argument to `commit` (or `put` / `upsert`):

```odin
// A handler that must not double-charge, even if the client retries or the
// connection drops after the daemon committed.
charge := make([dynamic]m.Cell, 2)
charge[0] = {1, m.string_value(order_id)}
charge[1] = {2, m.float_value(199.0)}

txn := m.begin(db)
defer m.free_transaction(&txn)
m.txn_put(&txn, "charges", charge[:], false)

// Use a stable, business-meaningful key derived from the request. On a retry
// with the same key the daemon returns the first commit's result instead of
// inserting a second row.
results, err := m.commit(&txn, "charge-order-123")
```

Rules for keys:

- Any non-empty string works. Prefer content-derived, globally-unique values
  (e.g. `"charge:" + order_id`).
- The empty string disables idempotency - a retry will commit again.
- The key scopes the **entire batch**, not individual ops. Reuse the exact same
  ops and key together when retrying.

## Handling constraint violations

Constraint violations arrive as HTTP 409, mapped to `.Conflict`. The daemon's
error envelope carries a structured `code` and an `op_index`; the client maps
the status to the typed error.

Check the category:

```odin
results, err := m.commit(&txn, "")
switch err {
case .None_:
	// ok - read `results`
case .Conflict:
	fmt.eprintf("constraint violated\n")
	// The engine already rolled back the whole batch. Nothing to undo.
case .Auth:
	fmt.eprintf("not authorized\n")
case:
	fmt.eprintf("commit failed: %s\n", m.mongrel_error_string(err))
}
```

Structured codes you will commonly see in the daemon's response:

| code | Meaning |
|------|---------|
| `UNIQUE_VIOLATION` | A unique/PK constraint rejected the commit |
| `FK_VIOLATION` | A foreign-key reference was missing |
| `CHECK_VIOLATION` | A check constraint or trigger rejected the commit |
| `NOT_FOUND` | A named resource (table, schema) does not exist |

## Rollback

There are two notions of "rollback":

1. **Server-side.** When `commit` fails with `.Conflict`, the engine has
   already discarded the entire batch. Nothing was written; there is no server
   rollback to perform.
2. **Client-side.** `rollback` clears the staged ops on a `Transaction` so a
   later `commit` is a no-op:

```odin
txn := m.begin(db)
defer m.free_transaction(&txn)
m.txn_put(&txn, "orders", cells[:], false)

if !business_rule_ok() {
	// Discard the batch locally. The daemon has seen nothing.
	m.rollback(&txn)
	return
}
results, _ := m.commit(&txn, "")
```

Calling `commit` or `rollback` on a transaction that has already been committed
or rolled back returns `.Already_Committed`.

## Lifecycle and memory

A `Transaction` is a value that owns a dynamic array of staged ops. Always pair
`begin` with `free_transaction(&t)` (a `defer` is the idiomatic place). The
`results` slice returned by `commit` is owned by the caller until its owning
JSON value is destroyed.

## Summary

| Goal | Use |
|------|-----|
| One independent write | `put` / `upsert` / `delete` / `delete_by_pk` |
| Several writes that must commit together | `begin` + stage `txn_*` + `commit` |
| Retry safely after a network blip | `commit` with a stable idempotency key |
| Distinguish constraint classes | Check `.Conflict` |
| Abort before sending | `rollback` - the batch is local |

See [errors.md](errors.md) for the full error set and [queries.md](queries.md)
for read patterns.
