// Example: query builder conditions with the MongrelDB Odin client.
//
// Build and run from the repo root (the `mdb` collection points the
// import at the `mongreldb/` package directory):
//
//   odin run examples/query_builder.odin -file -collection:mdb=.
//
// Requires a mongreldb-server daemon running on http://127.0.0.1:8453.
//
// Creates a table, inserts five rows with varying scores, then uses the native
// query builder to fetch rows by a range condition and by an exact primary-key
// match. Cleans up by dropping the table.

package query_builder

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

	// Unique table name per run so concurrent/repeated runs never collide.
	table := fmt.tprintf("example_query_%d", os.get_pid())
	defer m.free_string(table)

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

	// Five rows with varying scores.
	_, e1 := m.put(db, table, {
		{id = 1, value = m.int_value(1)},
		{id = 2, value = m.string_value("Alice")},
		{id = 3, value = m.float_value(40.0)},
	}, "")
	_, e2 := m.put(db, table, {
		{id = 1, value = m.int_value(2)},
		{id = 2, value = m.string_value("Bob")},
		{id = 3, value = m.float_value(65.0)},
	}, "")
	_, e3 := m.put(db, table, {
		{id = 1, value = m.int_value(3)},
		{id = 2, value = m.string_value("Carol")},
		{id = 3, value = m.float_value(82.0)},
	}, "")
	_, e4 := m.put(db, table, {
		{id = 1, value = m.int_value(4)},
		{id = 2, value = m.string_value("Dave")},
		{id = 3, value = m.float_value(91.0)},
	}, "")
	_, e5 := m.put(db, table, {
		{id = 1, value = m.int_value(5)},
		{id = 2, value = m.string_value("Eve")},
		{id = 3, value = m.float_value(12.5)},
	}, "")
	if e1 != .None_ || e2 != .None_ || e3 != .None_ || e4 != .None_ || e5 != .None_ {
		fmt.eprintf("insert failed\n")
		os.exit(1)
	}
	fmt.println("Inserted 5 rows")

	// Range condition: scores in [60.0, 90.0]. The "column" alias maps to the
	// server's column_id; pass the numeric column id (3), not the name.
	range_params := m.json_object_make()
	defer m.json_object_destroy(range_params)
	m.json_object_set(&range_params, "column", m.int_value(3))
	m.json_object_set(&range_params, "min", m.float_value(60.0))
	m.json_object_set(&range_params, "max", m.float_value(90.0))
	m.json_object_set(&range_params, "min_inclusive", m.bool_value(true))
	m.json_object_set(&range_params, "max_inclusive", m.bool_value(true))

	range_q := m.query(db, table)
	defer m.free_query_builder(&range_q)
	m.where_(&range_q, "range_f64", range_params)
	range_rows, rerr := m.execute(&range_q)
	if rerr != .None_ {
		fmt.eprintf("range query failed: %s\n", m.mongrel_error_string(rerr))
		os.exit(1)
	}
	fmt.printfln("Range query (score in [60,90]) returned %d rows:", len(range_rows))
	print_rows(range_rows)

	// Primary-key condition: fetch the single row with id == 4.
	pk_params := m.json_object_make()
	defer m.json_object_destroy(pk_params)
	m.json_object_set(&pk_params, "value", m.int_value(4))

	pk_q := m.query(db, table)
	defer m.free_query_builder(&pk_q)
	m.where_(&pk_q, "pk", pk_params)
	pk_rows, perr := m.execute(&pk_q)
	if perr != .None_ {
		fmt.eprintf("pk query failed: %s\n", m.mongrel_error_string(perr))
		os.exit(1)
	}
	fmt.printfln("PK query (id == 4) returned %d rows:", len(pk_rows))
	print_rows(pk_rows)
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

format_value :: proc(v: m.JSONValue) -> string {
	#partial switch val in v {
	case m.JSONString:
		return string(val)
	case:
		return "<value>"
	}
}
