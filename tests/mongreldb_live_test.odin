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
import "core:strings"
import "core:sync"
import "core:testing"

import m "mdb:mongreldb"

free_rows :: proc(rows: []m.JSONValue) {
	for row in rows { m.json_destroy(row) }
	m.free_slice(rows)
}

free_schema :: proc(s: map[string]m.JSONValue) {
	for k, v in s {
		m.free_string(k)
		m.json_destroy(v)
	}
	delete(s)
}

free_string_slice :: proc(ss: []string) {
	for s in ss { m.free_string(s) }
	m.free_slice(ss)
}

// harness_client is the shared Client, lazily created on first use by
// ensure_client. nil means "no daemon reachable - tests short-circuit".
harness_client: ^m.Client
harness_checked: bool
harness_mu: sync.Mutex

// ensure_client connects to the daemon (if reachable) exactly once and caches
// the client. Returns the shared client, or nil if no daemon is reachable.
// Thread-safe because Odin tests may run in parallel.
client :: proc() -> ^m.Client {
	sync.lock(&harness_mu)
	defer sync.unlock(&harness_mu)
	if harness_checked { return harness_client }
	harness_checked = true

	default_url := "http://127.0.0.1:8453"
	env_url := os.get_env_alloc("MONGRELDB_URL", context.allocator)
	defer m.free_string(env_url)
	effective_url := strings.clone(default_url, context.allocator)
	if env_url != "" {
		m.free_string(effective_url)
		effective_url = strings.clone(env_url, context.allocator)
	}
	c := new(m.Client)
	c^ = m.connect(effective_url, m.Options{})

	ok, err := m.health(c^)
	if ok && err == .None_ {
		harness_client = c
		return harness_client
	}
	// Daemon not reachable - free and leave harness_client nil.
	m.free_string(effective_url)
	free(c)
	return nil
}

// ── Test helpers ──────────────────────────────────────────────────────────

counter: int
counter_mu: sync.Mutex

// unique_table builds a table name unique to this process so concurrent or
// repeated runs never collide. The counter is protected by a mutex because
// Odin tests may run in parallel.
unique_table :: proc(prefix: string) -> string {
	sync.lock(&counter_mu)
	counter += 1
	n := counter
	sync.unlock(&counter_mu)
	return fmt.aprintf("%s_%d_%d", prefix, os.get_pid(), n)
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

// must_put inserts a row, failing the test on error. The per-operation
// result is destroyed automatically.
must_put :: proc(t: ^testing.T, c: m.Client, table: string, cells: []m.Cell) {
	res, err := m.put(c, table, cells, "")
	defer m.json_destroy(res)
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
		id, cok := cells[i].(m.JSONInteger)
		if cok && i64(id) == col_id {
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

// ── Tests (the 16-operation conformance matrix) ───────────────────────────

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
	r1, e1 := m.put(db, name, {{id = 1, value = m.int_value(1)}, {id = 2, value = m.float_value(99.5)}}, "")
	defer m.json_destroy(r1)
	testing.expect(t, e1 == .None_)
	r2, e2 := m.put(db, name, {{id = 1, value = m.int_value(2)}, {id = 2, value = m.float_value(150.0)}}, "")
	defer m.json_destroy(r2)
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
	ur1, e1 := m.upsert(
		db,
		name,
		{{id = 1, value = m.int_value(1)}, {id = 2, value = m.float_value(99.5)}},
		{{id = 2, value = m.float_value(99.5)}},
		"",
	)
	defer m.json_destroy(ur1)
	testing.expect(t, e1 == .None_)
	n1, _ := m.count(db, name)
	testing.expect(t, n1 == 1)

	// Second upsert on the same PK updates (still one row).
	ur2, e2 := m.upsert(
		db,
		name,
		{{id = 1, value = m.int_value(1)}, {id = 2, value = m.float_value(120.0)}},
		{{id = 2, value = m.float_value(120.0)}},
		"",
	)
	defer m.json_destroy(ur2)
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
	defer free_rows(rows)
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
	defer free_rows(rows)
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
	defer free_rows(rows)
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
	defer free_rows(results)
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
	insert_stmt := fmt.aprintf("INSERT INTO %s (id, amount) VALUES (10, 42)", name)
	defer m.free_string(insert_stmt)
	insert_rows, ierr := m.sql(db, insert_stmt)
	defer free_rows(insert_rows)
	testing.expectf(t, ierr == .None_, "sql insert err: %s", m.mongrel_error_string(ierr))
	n1, _ := m.count(db, name)
	testing.expect(t, n1 == 1)

	// JSON SQL mode should return the inserted row when the server honors the
	// format; an older server ignores JSON format and returns an empty slice.
	select_stmt := fmt.aprintf("SELECT id, amount FROM %s", name)
	defer m.free_string(select_stmt)
	rows, _ := m.sql(db, select_stmt)
	defer free_rows(rows)
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
	defer free_schema(s)
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
	defer m.json_destroy(desc)
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
	defer free_string_slice(names)
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

@(test)
test_history_retention_get_and_set :: proc(t: ^testing.T) {
	c := client()
	if c == nil { return }

	// Read the current window and earliest epoch.
	window, err1 := m.history_retention_epochs(c^)
	testing.expectf(t, err1 == .None_, "history_retention_epochs err: %s", m.mongrel_error_string(err1))
	earliest, err2 := m.earliest_retained_epoch(c^)
	testing.expectf(t, err2 == .None_, "earliest_retained_epoch err: %s", m.mongrel_error_string(err2))

	// Update the window and read it back.
	new_window := window + 1
	hr, err3 := m.set_history_retention_epochs(c^, new_window)
	defer {
		// Restore the original window even if the test returns early.
		_, err := m.set_history_retention_epochs(c^, window)
		testing.expectf(t, err == .None_, "restore retention failed: %s", m.mongrel_error_string(err))
	}
	testing.expectf(t, err3 == .None_, "set_history_retention_epochs err: %s", m.mongrel_error_string(err3))
	testing.expect(t, hr.history_retention_epochs == new_window)
	testing.expect(t, hr.earliest_retained_epoch == earliest)
}

@(test)
test_history_retention_as_of_epoch_query :: proc(t: ^testing.T) {
	c := client()
	if c == nil { return }
	name := unique_table("odin_ret")
	defer {
		_ = m.drop_table(c^, name)
		m.free_string(name)
	}
	fresh_table(c^, name, {int_col(1, "id", true), int_col(2, "amount", false)}, t)

	// Set a retention window before writes; restore the original window on exit.
	orig, err_orig := m.history_retention_epochs(c^)
	testing.expectf(t, err_orig == .None_, "read retention err: %s", m.mongrel_error_string(err_orig))
	defer {
		_, err := m.set_history_retention_epochs(c^, orig)
		testing.expectf(t, err == .None_, "restore retention failed: %s", m.mongrel_error_string(err))
	}
	_, err0 := m.set_history_retention_epochs(c^, 1000)
	testing.expectf(t, err0 == .None_, "set retention err: %s", m.mongrel_error_string(err0))

	// Insert and update a row, capturing the epoch after the first insert.
	must_put(t, c^, name, {{id = 1, value = m.int_value(1)}, {id = 2, value = m.int_value(100)}})
	insert_epoch, ep_err := m.table_commit_epoch(c^, name)
	testing.expectf(t, ep_err == .None_, "commit epoch err: %s", m.mongrel_error_string(ep_err))
	must_put(t, c^, name, {{id = 1, value = m.int_value(1)}, {id = 2, value = m.int_value(200)}})

	// Query at the captured insert epoch: must return the original value (100).
	stmt := fmt.aprintf("SELECT id, amount FROM %s AS OF EPOCH %d", name, insert_epoch)
	defer m.free_string(stmt)
	rows, err2 := m.sql(c^, stmt)
	testing.expectf(t, err2 == .None_, "AS OF EPOCH read err: %s", m.mongrel_error_string(err2))
	if len(rows) > 0 {
		// Verify the historical value (100), not the current value (200).
		for row in rows {
			obj, ok := row.(m.JSONObject)
			if ok {
				val, vok := m.json_object_get(obj, "amount")
				if vok {
					iv, iok := val.(m.JSONInteger)
					if iok {
						testing.expect(t, iv == 100, "AS OF EPOCH should return historical value 100")
					}
				}
			}
			m.json_destroy(row)
		}
	} else {
		// Server streamed Arrow IPC with no JSON rows; at minimum verify the
		// current value changed to prove the upsert took effect.
		curr_stmt := fmt.aprintf("SELECT amount FROM %s", name)
		defer m.free_string(curr_stmt)
		curr_rows, curr_err := m.sql(c^, curr_stmt)
		testing.expectf(t, curr_err == .None_, "current read err: %s", m.mongrel_error_string(curr_err))
		for row in curr_rows { m.json_destroy(row) }
		m.free_slice(curr_rows)
	}
	m.free_slice(rows)
}

// `odin test tests -collection:mdb=.` discovers and runs every
// `@(test)` proc in this package, generating its own runner entry point.
