// Example: basic CRUD operations with the MongrelDB Odin client.
//
// Build and run from the repo root (the `mdb` collection points the
// import at the `mongreldb/` package directory):
//
//   odin run examples/basic_crud.odin -file -collection:mdb=.
//
// Requires a mongreldb-server daemon running on http://127.0.0.1:8453.
//
// Creates a table, inserts three rows, counts them, queries all rows,
// "updates" one row by overwriting it at its primary key, deletes one row,
// then drops the table. Progress is printed at every step.

package basic_crud

import "core:fmt"
import "core:os"

import m "mdb:mongreldb"

URL :: "http://127.0.0.1:8453"

main :: proc() {
	db := m.connect(URL, m.Options{})

	// Health check; bail out if the daemon is unreachable.
	ok, err := m.health(db)
	if !ok || err != .None_ {
		fmt.eprintf("daemon not reachable at %s\n", URL)
		os.exit(1)
	}
	fmt.println("Connected to MongrelDB")

	// Unique table name per run so concurrent/repeated runs never collide.
	table := fmt.aprintf("example_crud_%d", os.get_pid())
	defer m.free_string(table)

	// Always drop the table on exit.
	defer {
		_ = m.drop_table(db, table)
		fmt.println("Dropped table", table)
	}

	// Create the table. Schema: id (int64 PK), name (varchar), score (float64).
	tid, cerr := m.create_table(db, table, {
		m.Column{id = 1, name = "id", ty = "int64", primary_key = true},
		m.Column{id = 2, name = "name", ty = "varchar"},
		m.Column{id = 3, name = "score", ty = "float64"},
	})
	if cerr != .None_ {
		fmt.eprintf("create_table failed: %s\n", m.mongrel_error_string(cerr))
		os.exit(1)
	}
	fmt.println("Created table", table, "(id", tid, ")")

	// Insert three rows. Cells pair column id -> value. The first return value
	// is the per-operation result object and must be destroyed.
	r1, p1 := m.put(db, table, {
		{id = 1, value = m.int_value(1)},
		{id = 2, value = m.string_value("Alice")},
		{id = 3, value = m.float_value(95.5)},
	}, "")
	defer m.json_destroy(r1)
	r2, p2 := m.put(db, table, {
		{id = 1, value = m.int_value(2)},
		{id = 2, value = m.string_value("Bob")},
		{id = 3, value = m.float_value(82.0)},
	}, "")
	defer m.json_destroy(r2)
	r3, p3 := m.put(db, table, {
		{id = 1, value = m.int_value(3)},
		{id = 2, value = m.string_value("Carol")},
		{id = 3, value = m.float_value(78.3)},
	}, "")
	defer m.json_destroy(r3)
	if p1 != .None_ || p2 != .None_ || p3 != .None_ {
		fmt.eprintf("insert failed\n")
		os.exit(1)
	}
	fmt.println("Inserted 3 rows")

	total, _ := m.count(db, table)
	fmt.println("Total rows:", total)

	// Query all rows (no conditions).
	all_q := m.query(db, table)
	defer m.free_query_builder(&all_q)
	rows, qerr := m.execute(&all_q)
	if qerr != .None_ {
		fmt.eprintf("query failed: %s\n", m.mongrel_error_string(qerr))
		os.exit(1)
	}
	defer free_rows(rows)
	fmt.printfln("Query returned %d rows:", len(rows))
	print_rows(rows)

	// Update Alice's score by re-putting the same primary key with new values.
	// The PK is the row identity, so a put to an existing PK overwrites it.
	ur, uerr := m.put(db, table, {
		{id = 1, value = m.int_value(1)},
		{id = 2, value = m.string_value("Alice")},
		{id = 3, value = m.float_value(100.0)},
	}, "")
	defer m.json_destroy(ur)
	if uerr != .None_ {
		fmt.eprintf("update failed: %s\n", m.mongrel_error_string(uerr))
		os.exit(1)
	}
	fmt.println("Updated Alice's score to 100.0")

	after_update, _ := m.count(db, table)
	fmt.println("Total rows after update:", after_update)

	// Delete Carol (primary key 3).
	derr := m.delete_by_pk(db, table, m.int_value(3))
	if derr != .None_ {
		fmt.eprintf("delete failed: %s\n", m.mongrel_error_string(derr))
		os.exit(1)
	}
	after_delete, _ := m.count(db, table)
	fmt.println("Deleted Carol; remaining rows:", after_delete)
}

// print_rows prints each row object from a query result array.
print_rows :: proc(rows: []m.JSONValue) {
	for row_val in rows {
		o, ok := row_val.(m.JSONObject)
		if !ok { continue }
		fmt.print("  { ")
		first := true
		for i in 0..<m.json_object_len(o) {
			if !first { fmt.print(", ") }
			fmt.print(o.keys[i], "=", format_value(o.values[i]))
			first = false
		}
		fmt.println(" }")
	}
}

free_rows :: proc(rows: []m.JSONValue) {
	for row in rows { m.json_destroy(row) }
	m.free_slice(rows)
}

format_value :: proc(v: m.JSONValue) -> string {
	#partial switch val in v {
	case m.JSONString:
		return string(val)
	case:
		return "<value>"
	}
}
