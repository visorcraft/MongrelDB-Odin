// Live integration tests for the mongreldb Odin client.
//
// These connect to a running mongreldb-server daemon and exercise the client
// end to end. The daemon URL is resolved in this order:
//   1. MONGRELDB_URL env var (a daemon already running and reachable).
//   2. The default http://127.0.0.1:8453.
//
// If no daemon is reachable, every live test returns early without asserting
// (it passes vacuously, effectively a skip). This lets the same suite run both
// offline (CI build job) and against a real server (CI live job).

package mongreldb_test

import "core:fmt"
import "core:os"
import "core:testing"

import m "mongreldb"

// harness_client is the shared Client, lazily created on first use by
// ensure_client. nil means "no daemon reachable - tests short-circuit".
harness_client: ^m.Client
harness_checked: bool

// ensure_client connects to the daemon (if reachable) exactly once and caches
// the client. Returns the shared client, or nil if no daemon is reachable.
client :: proc() -> ^m.Client {
	if harness_checked { return harness_client }
	harness_checked = true

	url := "http://127.0.0.1:8453"
	if env_url := os.get_env_alloc("MONGRELDB_URL", context.allocator); env_url != "" {
		url = env_url
		m.free_string(env_url)
	}
	c := new(m.Client)
	c^ = m.connect(url, m.Options{})

	ok, err := m.health(c^)
	if ok && err == .None_ {
		harness_client = c
		return harness_client
	}
	// Daemon not reachable - free and leave harness_client nil.
	free(c)
	return nil
}

// ── Test helpers ──────────────────────────────────────────────────────────

counter: int

// unique_table builds a table name unique to this process so concurrent or
// repeated runs never collide.
unique_table :: proc(prefix: string) -> string {
	counter += 1
	return fmt.tprintf("%s_%d_%d", prefix, os.get_pid(), counter)
}

int_col :: proc(id: i64, name: string, primary_key: bool) -> m.Column {
	return m.Column{
		id = id, name = name, ty = "int64",
		primary_key = primary_key, nullable = false,
	}
}

float_col :: proc(id: i64, name: string) -> m.Column {
	return m.Column{
		id = id, name = name, ty = "float64",
		primary_key = false, nullable = false,
	}
}

// fresh_table drops (best-effort) then creates the table with `columns`.
fresh_table :: proc(c: m.Client, name: string, columns: []m.Column, t: ^testing.T) {
	_ = m.drop_table(c, name)
	_, err := m.create_table(c, name, columns)
	if err != .None_ {
		fmt.eprintf("create_table failed: %s\n", m.mongrel_error_string(err))
		testing.fail(t)
	}
}

// must_put inserts a row, failing the test on error.
must_put :: proc(t: ^testing.T, c: m.Client, table: string, cells: []m.Cell) {
	_, err := m.put(c, table, cells, "")
	if err != .None_ {
		fmt.eprintf("put failed: %s\n", m.mongrel_error_string(err))
		testing.fail(t)
	}
}

// cell_value extracts the value for col_id from a Kit row object's flat
// `cells` array (shape: [col_id, value, ...]), or nil if absent.
cell_value :: proc(row: m.JSONValue, col_id: i64) -> m.JSONValue {
	o, ok := row.(m.JSONObject)
	if !ok { return nil }
	cells_v, has := m.json_object_get(o, "cells")
	if !has { return nil }
	cells, ok2 := cells_v.(m.JSONArray)
	if !ok2 { return nil }
	i := 0
	for i + 1 < len(cells) {
		id, ok := cells[i].(m.JSONInteger)
		if ok && i64(id) == col_id {
			return cells[i + 1]
		}
		i += 2
	}
	return nil
}

cell_int64 :: proc(row: m.JSONValue, col_id: i64) -> (i64, bool) {
	v := cell_value(row, col_id)
	if v == nil { return 0, false }
	n, ok := v.(m.JSONInteger)
	return i64(n), ok
}

cell_float64 :: proc(row: m.JSONValue, col_id: i64) -> (f64, bool) {
	v := cell_value(row, col_id)
	if v == nil { return 0, false }
	#partial switch val in v {
	case m.JSONFloat:
		return f64(val), true
	case m.JSONInteger:
		return f64(val), true
	case:
		return 0, false
	}
}

// ── Tests (the 14-operation conformance matrix) ───────────────────────────

@(test)
test_health :: proc(t: ^testing.T) {
	c := client()
	if c == nil { return }
	ok, err := m.health(c^)
	testing.expectf(t, ok && err == .None_, "health: ok=%v err=%s", ok, m.mongrel_error_string(err))
}

@(test)
test_create_table_and_count :: proc(t: ^testing.T) {
	c := client()
	if c == nil { return }
	name := unique_table("odin_tbl")
	defer {
		_ = m.drop_table(c^, name)
		m.free_string(name)
	}
	fresh_table(c^, name, {int_col(1, "id", true), float_col(2, "amount")}, t)

	n, err := m.count(c^, name)
	testing.expectf(t, err == .None_, "count err: %s", m.mongrel_error_string(err))
	testing.expect(t, n == 0)
}

@(test)
test_put_and_count_round_trip :: proc(t: ^testing.T) {
	c := client()
	if c == nil { return }
	name := unique_table("odin_put")
	defer {
		_ = m.drop_table(c^, name)
		m.free_string(name)
	}
	fresh_table(c^, name, {int_col(1, "id", true), float_col(2, "amount")}, t)

	db := c^
	_, e1 := m.put(db, name, {{id = 1, value = m.int_value(1)}, {id = 2, value = m.float_value(99.5)}}, "")
	testing.expect(t, e1 == .None_)
	_, e2 := m.put(db, name, {{id = 1, value = m.int_value(2)}, {id = 2, value = m.float_value(150.0)}}, "")
	testing.expect(t, e2 == .None_)

	n, _ := m.count(db, name)
	testing.expect(t, n == 2)
}

@(test)
test_upsert_inserts_then_updates :: proc(t: ^testing.T) {
	c := client()
	if c == nil { return }
	name := unique_table("odin_upsert")
	defer {
		_ = m.drop_table(c^, name)
		m.free_string(name)
	}
	fresh_table(c^, name, {int_col(1, "id", true), float_col(2, "amount")}, t)

	db := c^
	// First upsert inserts.
	_, e1 := m.upsert(
		db,
		name,
		{{id = 1, value = m.int_value(1)}, {id = 2, value = m.float_value(99.5)}},
		{{id = 2, value = m.float_value(99.5)}},
		"",
	)
	testing.expect(t, e1 == .None_)
	n1, _ := m.count(db, name)
	testing.expect(t, n1 == 1)

	// Second upsert on the same PK updates (still one row).
	_, e2 := m.upsert(
		db,
		name,
		{{id = 1, value = m.int_value(1)}, {id = 2, value = m.float_value(120.0)}},
		{{id = 2, value = m.float_value(120.0)}},
		"",
	)
	testing.expect(t, e2 == .None_)
	n2, _ := m.count(db, name)
	testing.expect(t, n2 == 1)

	// The updated value is visible via a PK query.
	pk := m.json_object_make()
	defer m.json_object_destroy(pk)
	m.json_object_set(&pk, "value", m.int_value(1))
	qb := m.query(db, name)
	defer m.free_query_builder(&qb)
	m.where_(&qb, "pk", pk)
	rows, qerr := m.execute(&qb)
	testing.expectf(t, qerr == .None_, "query err: %s", m.mongrel_error_string(qerr))
	testing.expect(t, len(rows) == 1)
	if len(rows) == 1 {
		id, _ := cell_int64(rows[0], 1)
		amt, _ := cell_float64(rows[0], 2)
		testing.expect(t, id == 1)
		testing.expect(t, amt == 120.0)
	}
}

@(test)
test_query_by_pk :: proc(t: ^testing.T) {
	c := client()
	if c == nil { return }
	name := unique_table("odin_pk")
	defer {
		_ = m.drop_table(c^, name)
		m.free_string(name)
	}
	fresh_table(c^, name, {int_col(1, "id", true)}, t)

	db := c^
	must_put(t, db, name, {{id = 1, value = m.int_value(42)}})
	must_put(t, db, name, {{id = 1, value = m.int_value(43)}})

	pk := m.json_object_make()
	defer m.json_object_destroy(pk)
	m.json_object_set(&pk, "value", m.int_value(42))
	qb := m.query(db, name)
	defer m.free_query_builder(&qb)
	m.where_(&qb, "pk", pk)
	rows, qerr := m.execute(&qb)
	testing.expectf(t, qerr == .None_, "query err: %s", m.mongrel_error_string(qerr))
	testing.expect(t, len(rows) == 1)
	if len(rows) == 1 {
		v, _ := cell_int64(rows[0], 1)
		testing.expect(t, v == 42)
	}
}

@(test)
test_query_range :: proc(t: ^testing.T) {
	c := client()
	if c == nil { return }
	name := unique_table("odin_range")
	defer {
		_ = m.drop_table(c^, name)
		m.free_string(name)
	}
	fresh_table(c^, name, {int_col(1, "id", true), int_col(2, "amount", false)}, t)

	db := c^
	must_put(t, db, name, {{id = 1, value = m.int_value(1)}, {id = 2, value = m.int_value(50)}})
	must_put(t, db, name, {{id = 1, value = m.int_value(2)}, {id = 2, value = m.int_value(120)}})
	must_put(t, db, name, {{id = 1, value = m.int_value(3)}, {id = 2, value = m.int_value(200)}})

	rng := m.json_object_make()
	defer m.json_object_destroy(rng)
	m.json_object_set(&rng, "column", m.int_value(2))
	m.json_object_set(&rng, "min", m.int_value(100))
	m.json_object_set(&rng, "max", m.int_value(150))
	qb := m.query(db, name)
	defer m.free_query_builder(&qb)
	m.where_(&qb, "range", rng)
	rows, qerr := m.execute(&qb)
	testing.expectf(t, qerr == .None_, "query err: %s", m.mongrel_error_string(qerr))
	// Only the row with amount=120 (pk=2) falls in [100, 150].
	testing.expect(t, len(rows) == 1)
	if len(rows) == 1 {
		amt, _ := cell_int64(rows[0], 2)
		testing.expect(t, amt >= 100 && amt <= 150)
	}
}

@(test)
test_transaction_put_commit :: proc(t: ^testing.T) {
	c := client()
	if c == nil { return }
	name := unique_table("odin_txn")
	defer {
		_ = m.drop_table(c^, name)
		m.free_string(name)
	}
	fresh_table(c^, name, {int_col(1, "id", true)}, t)

	db := c^
	txn := m.begin(db)
	defer m.free_transaction(&txn)
	_, e1 := m.txn_put(&txn, name, {{id = 1, value = m.int_value(1)}}, false)
	testing.expect(t, e1 == .None_)
	_, e2 := m.txn_put(&txn, name, {{id = 1, value = m.int_value(2)}}, false)
	testing.expect(t, e2 == .None_)
	_, e3 := m.txn_put(&txn, name, {{id = 1, value = m.int_value(3)}}, false)
	testing.expect(t, e3 == .None_)
	testing.expect(t, m.txn_count(txn) == 3)

	results, cerr := m.commit(&txn, "")
	testing.expectf(t, cerr == .None_, "commit err: %s", m.mongrel_error_string(cerr))
	testing.expect(t, len(results) == 3)

	n, _ := m.count(db, name)
	testing.expect(t, n == 3)
}

@(test)
test_delete_by_pk :: proc(t: ^testing.T) {
	c := client()
	if c == nil { return }
	name := unique_table("odin_del")
	defer {
		_ = m.drop_table(c^, name)
		m.free_string(name)
	}
	fresh_table(c^, name, {int_col(1, "id", true)}, t)

	db := c^
	must_put(t, db, name, {{id = 1, value = m.int_value(5)}})
	n1, _ := m.count(db, name)
	testing.expect(t, n1 == 1)

	err := m.delete_by_pk(db, name, m.int_value(5))
	testing.expect(t, err == .None_)
	n2, _ := m.count(db, name)
	testing.expect(t, n2 == 0)
}

@(test)
test_sql_insert_and_select :: proc(t: ^testing.T) {
	c := client()
	if c == nil { return }
	name := unique_table("odin_sql")
	defer {
		_ = m.drop_table(c^, name)
		m.free_string(name)
	}
	fresh_table(c^, name, {int_col(1, "id", true), int_col(2, "amount", false)}, t)

	db := c^
	n0, _ := m.count(db, name)
	testing.expect(t, n0 == 0)

	// INSERT via SQL must increase the row count.
	insert_stmt := fmt.tprintf("INSERT INTO %s (id, amount) VALUES (10, 42)", name)
	defer m.free_string(insert_stmt)
	_, ierr := m.sql(db, insert_stmt)
	testing.expectf(t, ierr == .None_, "sql insert err: %s", m.mongrel_error_string(ierr))
	n1, _ := m.count(db, name)
	testing.expect(t, n1 == 1)

	// JSON SQL mode should return the inserted row when the server honors the
	// format; an older server ignores JSON format and returns an empty slice.
	select_stmt := fmt.tprintf("SELECT id, amount FROM %s", name)
	defer m.free_string(select_stmt)
	rows, _ := m.sql(db, select_stmt)
	if len(rows) > 0 {
		testing.expect(t, len(rows) == 1)
	}
}

@(test)
test_schema :: proc(t: ^testing.T) {
	c := client()
	if c == nil { return }
	name := unique_table("odin_schema")
	defer {
		_ = m.drop_table(c^, name)
		m.free_string(name)
	}
	fresh_table(c^, name, {int_col(1, "id", true), float_col(2, "amount")}, t)

	s, err := m.schema(c^)
	testing.expectf(t, err == .None_, "schema err: %s", m.mongrel_error_string(err))
	_, present := s[name]
	testing.expectf(t, present, "schema missing table %s", name)
}

@(test)
test_schema_for :: proc(t: ^testing.T) {
	c := client()
	if c == nil { return }
	name := unique_table("odin_schema_for")
	defer {
		_ = m.drop_table(c^, name)
		m.free_string(name)
	}
	fresh_table(c^, name, {int_col(1, "id", true), float_col(2, "amount")}, t)

	desc, err := m.schema_for(c^, name)
	testing.expectf(t, err == .None_, "schema_for err: %s", m.mongrel_error_string(err))
	o, ok := desc.(m.JSONObject)
	testing.expect(t, ok)
	if ok {
		_, has_id := m.json_object_get(o, "schema_id")
		testing.expect(t, has_id)
		cols_v, has_cols := m.json_object_get(o, "columns")
		testing.expect(t, has_cols)
		cols, _ := cols_v.(m.JSONArray)
		testing.expect(t, len(cols) == 2)
	}
}

@(test)
test_table_names_lists_created_table :: proc(t: ^testing.T) {
	c := client()
	if c == nil { return }
	name := unique_table("odin_tables")
	defer {
		_ = m.drop_table(c^, name)
		m.free_string(name)
	}
	fresh_table(c^, name, {int_col(1, "id", true)}, t)

	names, err := m.table_names(c^)
	testing.expectf(t, err == .None_, "table_names err: %s", m.mongrel_error_string(err))
	found := false
	for n in names {
		if n == name { found = true; break }
	}
	testing.expectf(t, found, "table_names missing %s", name)
}

@(test)
test_error_on_nonexistent_table :: proc(t: ^testing.T) {
	c := client()
	if c == nil { return }
	name := unique_table("odin_missing")
	defer m.free_string(name)
	// schema_for on a nonexistent table maps a 404 to .Not_Found.
	_, err := m.schema_for(c^, name)
	testing.expectf(t, err == .Not_Found, "expected Not_Found, got %s", m.mongrel_error_string(err))
}

@(test)
test_error_type_carries_status :: proc(t: ^testing.T) {
	c := client()
	if c == nil { return }
	name := unique_table("odin_missing2")
	defer m.free_string(name)
	// A second lookup also maps the 404 status to the typed Not_Found error.
	_, err := m.schema_for(c^, name)
	testing.expectf(t, err == .Not_Found, "expected Not_Found, got %s", m.mongrel_error_string(err))
}

// `odin test tests -collection:mongreldb=src` discovers and runs every
// `@(test)` proc in this package, generating its own runner entry point.
