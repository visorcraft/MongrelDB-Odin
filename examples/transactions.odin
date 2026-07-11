// Example: atomic batch transactions with the MongrelDB Odin client.
//
// Build and run from the repo root (the `mdb` collection points the
// import at the `mongreldb/` package directory):
//
//   odin run examples/transactions.odin -file -collection:mdb=.
//
// Requires a mongreldb-server daemon running on http://127.0.0.1:8453.
//
// Creates a table, stages three inserts in a single transaction, commits them
// atomically, verifies the count, then demonstrates idempotent retries by
// re-committing with the same idempotency key (the daemon returns the original
// result and applies no duplicate rows). Cleans up by dropping the table.

package transactions

import "core:fmt"
import "core:os"

import m "mdb:mongreldb"

URL :: "http://127.0.0.1:8453"

main :: proc() {
	db := m.connect(URL, m.Options{})

	ok, err := m.health(db)
	if !ok || err != .None_ {
		fmt.eprintf("daemon not reachable at %s\n", URL)
		os.exit(1)
	}
	fmt.println("Connected to MongrelDB")

	// Unique table name + idempotency key per run so concurrent/repeated runs
	// never collide and retry logic isn't confused with a prior run's batch.
	ts := os.get_pid()
	table := fmt.aprintf("example_txn_%d", ts)
	defer m.free_string(table)
	idempotency_key := fmt.aprintf("example-txn-%d", ts)
	defer m.free_string(idempotency_key)

	// Always drop the table on exit.
	defer {
		_ = m.drop_table(db, table)
		fmt.println("Dropped table", table)
	}

	_, cerr := m.create_table(db, table, {
		m.Column{id = 1, name = "id", ty = "int64", primary_key = true},
		m.Column{id = 2, name = "name", ty = "varchar"},
		m.Column{id = 3, name = "score", ty = "float64"},
	})
	if cerr != .None_ {
		fmt.eprintf("create_table failed: %s\n", m.mongrel_error_string(cerr))
		os.exit(1)
	}
	fmt.println("Created table", table)

	// Stage three puts and commit them atomically. Either every op lands or
	// none do; a constraint violation rolls back the whole batch.
	txn := m.begin(db)
	defer m.free_transaction(&txn)
	_, te1 := m.txn_put(&txn, table, {
		{id = 1, value = m.int_value(1)},
		{id = 2, value = m.string_value("Alice")},
		{id = 3, value = m.float_value(95.5)},
	}, false)
	_, te2 := m.txn_put(&txn, table, {
		{id = 1, value = m.int_value(2)},
		{id = 2, value = m.string_value("Bob")},
		{id = 3, value = m.float_value(82.0)},
	}, false)
	_, te3 := m.txn_put(&txn, table, {
		{id = 1, value = m.int_value(3)},
		{id = 2, value = m.string_value("Carol")},
		{id = 3, value = m.float_value(78.3)},
	}, false)
	if te1 != .None_ || te2 != .None_ || te3 != .None_ {
		fmt.eprintf("stage failed\n")
		os.exit(1)
	}
	fmt.println("Staged", m.txn_count(txn), "operations")

	results, cmerr := m.commit(&txn, "")
	if cmerr != .None_ {
		fmt.eprintf("commit failed: %s\n", m.mongrel_error_string(cmerr))
		os.exit(1)
	}
	defer free_rows(results)
	fmt.printfln("Committed atomically: %d operations applied", len(results))

	after_commit, _ := m.count(db, table)
	fmt.printfln("Verified row count after commit: %d", after_commit)

	// Idempotent retry: stage the same batch again with an idempotency key,
	// then commit a second time with the SAME key. The daemon replays the
	// original result and applies no extra rows.
	retry := m.begin(db)
	defer m.free_transaction(&retry)
	_, re1 := m.txn_put(&retry, table, {
		{id = 1, value = m.int_value(4)},
		{id = 2, value = m.string_value("Dave")},
		{id = 3, value = m.float_value(60.0)},
	}, false)
	if re1 != .None_ {
		fmt.eprintf("retry stage failed\n")
		os.exit(1)
	}
	_, rerr := m.commit(&retry, idempotency_key)
	if rerr != .None_ {
		fmt.eprintf("retry commit failed: %s\n", m.mongrel_error_string(rerr))
		os.exit(1)
	}
	after_first, _ := m.count(db, table)
	fmt.printfln("After first idempotent commit: %d rows", after_first)

	retry2 := m.begin(db)
	defer m.free_transaction(&retry2)
	_, re2 := m.txn_put(&retry2, table, {
		{id = 1, value = m.int_value(4)},
		{id = 2, value = m.string_value("Dave")},
		{id = 3, value = m.float_value(60.0)},
	}, false)
	if re2 != .None_ {
		fmt.eprintf("retry2 stage failed\n")
		os.exit(1)
	}
	_, rerr2 := m.commit(&retry2, idempotency_key)
	if rerr2 != .None_ {
		fmt.eprintf("duplicate commit failed: %s\n", m.mongrel_error_string(rerr2))
		os.exit(1)
	}
	after_dup, _ := m.count(db, table)
	fmt.printfln("After duplicate idempotent commit (same key): %d rows (no double-apply)", after_dup)
}

free_rows :: proc(rows: []m.JSONValue) {
	for row in rows { m.json_destroy(row) }
	m.free_slice(rows)
}
