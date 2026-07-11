// mongreldb is the pure-Odin HTTP client for [MongrelDB].
//
// It talks to a running mongreldb-server daemon's JSON API over libcurl (via a
// small C FFI wrapper in `curl.odin`). No package manager is required - just
// source files. The surface mirrors the MongrelDB PHP and Go clients: typed
// CRUD, a fluent query builder that pushes conditions down to the engine's
// native indexes, idempotent batch transactions, full SQL access, and schema
// introspection.
//
// Connect with `connect` and a base URL:
//
// ```odin
// db := mongreldb.connect("http://127.0.0.1:8453", mongreldb.Options{})
// ok, err := db.health()
// if err != .None_ { panic(mongreldb.mongrel_error_string(err)) }
// ```
//
// [MongrelDB]: https://www.MongrelDB.com

package mongreldb

import "core:fmt"
import "core:mem"
import "core:strings"

// default_base_url is the daemon address used when none is supplied.
default_base_url :: "http://127.0.0.1:8453"

// max_response_bytes caps the size of a response body read from the daemon
// (256 MB). Bodies larger than this are aborted as a `.Response_Too_Large`
// error.
max_response_bytes :: u64(268_435_456)

// Mongrel_Error is the typed error returned by every client operation. HTTP
// status codes are mapped to a category: 401/403 -> `.Auth`, 404 ->
// `.Not_Found`, 409 -> `.Conflict`, any other non-2xx -> `.Query`. Transport
// failures are reported as `.Http`, malformed responses as `.Json`. `.None_`
// is the success sentinel.
Mongrel_Error :: enum {
	None_,
	Http,
	Json,
	Auth,
	Not_Found,
	Conflict,
	Query,
	Response_Too_Large,
	Already_Committed,
}

// mongrel_error_string returns a human-readable label for an error variant.
mongrel_error_string :: proc(e: Mongrel_Error) -> string {
	#partial switch e {
	case .None_:
		return "ok"
	case .Http:
		return "http transport error"
	case .Json:
		return "malformed JSON response"
	case .Auth:
		return "authentication/authorization failed"
	case .Not_Found:
		return "not found"
	case .Conflict:
		return "constraint violation / conflict"
	case .Query:
		return "query/server error"
	case .Response_Too_Large:
		return "response body exceeded limit"
	case .Already_Committed:
		return "transaction already committed"
	}
	return "unknown error"
}

// Cell pairs a column id with its value. The client flattens a slice of cells
// to the server's on-wire `[col_id, value, col_id, value, ...]` array before
// sending.
Cell :: struct {
	id:    i64,
	value: JSONValue,
}

// Column describes one column in a CREATE TABLE request. It is serialized
// verbatim; the recognized keys are `id`, `name`, `ty`, `primary_key`,
// `nullable`, `enum_variants`, and `default_value`, matching the daemon's
// table-create extractor. `enum_variants` and `default_value` are optional and
// only emitted when their `has_*` flag is set.
Column :: struct {
	id:            i64,
	name:          string,
	ty:            string,
	primary_key:   bool,
	nullable:      bool,
	has_enum:      bool,
	enum_variants: [dynamic]string,
	has_default:   bool,
	default_value: string,
	// default_scalar sends a non-string JSON scalar as default_value.
	has_default_scalar: bool,
	default_scalar:     JSONValue,
	has_default_expr: bool,
	default_expr:     string,
}

// Options configures a `Client`.
Options :: struct {
	// token authenticates requests with a Bearer token (--auth-token mode).
	// When set, it takes precedence over basic-auth credentials.
	token: string,
	// username / password authenticate with HTTP Basic credentials
	// (--auth-users mode). Ignored if `token` is also supplied.
	username: string,
	password: string,
}

// Client is the MongrelDB HTTP client. Create one with `connect`.
Client :: struct {
	base_url: string,
	token:    string,
	username: string,
	password: string,
}

// connect returns a `Client` for the daemon at `base_url`. If `base_url`
// is empty, `default_base_url` is used. The base URL has any trailing slash
// trimmed.
connect :: proc(base_url: string, options: Options) -> Client {
	url := default_base_url
	if base_url != "" {
		url = strings.trim_right(base_url, "/")
	}
	return Client{
		base_url = url,
		token = options.token,
		username = options.username,
		password = options.password,
	}
}

// ── Health & tables ───────────────────────────────────────────────────────

// health reports whether the daemon is reachable and healthy.
health :: proc(db: Client, allocator := context.allocator) -> (bool, Mongrel_Error) {
	body, err := raw_request(db, allocator, .GET, "/health", nil)
	if err != .None_ { return false, err }
	if body != nil { free_slice(body, allocator) }
	return true, .None_
}

// table_names lists all table names in the database.
table_names :: proc(db: Client, allocator := context.allocator) -> ([]string, Mongrel_Error) {
	body, err := raw_request(db, allocator, .GET, "/tables", nil)
	if err != .None_ { return nil, err }
	defer free_slice(body, allocator)

	value, jerr := json_parse(body, allocator)
	if jerr != "" { return nil, .Json }
	defer json_destroy(value, allocator)

	arr, ok := value.(JSONArray)
	if !ok { return nil, .Json }
	out := make([dynamic]string, 0, len(arr), allocator)
	for item in arr {
		s, sok := item.(JSONString)
		if !sok { free_dyn(out); return nil, .Json }
		append(&out, s)
	}
	return out[:], .None_
}

// create_table creates a table named `name` with the given columns and
// returns the assigned table id.
create_table :: proc(db: Client, name: string, columns: []Column, allocator := context.allocator) -> (i64, Mongrel_Error) {
	return create_table_impl(db, name, columns, JSONNull{}, false, allocator)
}

// create_table_with_constraints creates a table and adds the supplied
// top-level engine constraints object, for example
// `{checks: [{name = "id_present", expr = ...}]}`. The caller retains
// ownership of `constraints`.
create_table_with_constraints :: proc(db: Client, name: string, columns: []Column, constraints: JSONValue, allocator := context.allocator) -> (i64, Mongrel_Error) {
	return create_table_impl(db, name, columns, constraints, true, allocator)
}

// create_table_payload builds the request object and its owned column array.
// The returned constraints value is borrowed and remains owned by the caller.
create_table_payload :: proc(name: string, columns: []Column, constraints: JSONValue, include_constraints: bool, allocator := context.allocator) -> (JSONObject, [dynamic]JSONValue) {
	cols := make([dynamic]JSONValue, 0, len(columns), allocator)
	for c in columns {
		append(&cols, column_to_value(c, allocator))
	}
	obj := json_object_make(allocator)
	json_object_set(&obj, "name", jstr(name, allocator))
	json_object_set(&obj, "columns", JSONArray(cols))
	if include_constraints {
		json_object_set(&obj, "constraints", constraints)
	}
	return obj, cols
}

create_table_impl :: proc(db: Client, name: string, columns: []Column, constraints: JSONValue, include_constraints: bool, allocator: mem.Allocator) -> (i64, Mongrel_Error) {
	obj, cols := create_table_payload(name, columns, constraints, include_constraints, allocator)
	defer json_destroy(JSONArray(cols), allocator)
	defer json_object_destroy(obj)
	payload := obj

	body, err := raw_request(db, allocator, .POST, "/kit/create_table", payload)
	if err != .None_ { return 0, err }
	defer free_slice(body, allocator)

	value, jerr := json_parse(body, allocator)
	if jerr != "" { return 0, .Json }
	defer json_destroy(value, allocator)

	o, ok := value.(JSONObject)
	if !ok { return 0, .Json }
	tid_any, has := json_object_get(o, "table_id")
	if !has { return 0, .Json }
	tid, ok2 := tid_any.(JSONInteger)
	if !ok2 { return 0, .Json }
	return i64(tid), .None_
}

// drop_table drops a table by name.
drop_table :: proc(db: Client, name: string, allocator := context.allocator) -> Mongrel_Error {
	escaped := url_path_escape(name, allocator)
	defer if escaped != name { free_string(escaped, allocator) }
	path := fmt.tprintf("/tables/%s", escaped)
	defer free_string(path)
	body, err := raw_request(db, allocator, .DELETE, path, nil)
	if err != .None_ { return err }
	if body != nil { free_slice(body, allocator) }
	return .None_
}

// count returns the row count for a table.
count :: proc(db: Client, table: string, allocator := context.allocator) -> (i64, Mongrel_Error) {
	escaped := url_path_escape(table, allocator)
	defer if escaped != table { free_string(escaped, allocator) }
	path := fmt.tprintf("/tables/%s/count", escaped)
	defer free_string(path)
	body, err := raw_request(db, allocator, .GET, path, nil)
	if err != .None_ { return 0, err }
	defer free_slice(body, allocator)

	value, jerr := json_parse(body, allocator)
	if jerr != "" { return 0, .Json }
	defer json_destroy(value, allocator)

	o, ok := value.(JSONObject)
	if !ok { return 0, .Json }
	c_any, has := json_object_get(o, "count")
	if !has { return 0, .Json }
	c, ok2 := c_any.(JSONInteger)
	if !ok2 { return 0, .Json }
	return i64(c), .None_
}

// ── CRUD (via the Kit typed transaction endpoint) ─────────────────────────

// put inserts a row. `idempotency_key`, if non-empty, makes the commit safe
// to retry. Returns the per-operation result object (the first element of the
// server's results array).
put :: proc(db: Client, table: string, cells: []Cell, idempotency_key: string, allocator := context.allocator) -> (JSONValue, Mongrel_Error) {
	results, err := single_txn(db, table, cells, idempotency_key, "put", allocator)
	if err != .None_ { return JSONNull{}, err }
	if len(results) == 0 { return JSONNull{}, .None_ }
	return results[0], .None_
}

// upsert inserts a row, or updates it on a primary-key conflict. `cells`
// are the insert values; `update_cells`, when non-empty, are the values to
// apply on a conflict (an empty slice means DO NOTHING).
upsert :: proc(db: Client, table: string, cells: []Cell, update_cells: []Cell, idempotency_key: string, allocator := context.allocator) -> (JSONValue, Mongrel_Error) {
	inner := json_object_make(allocator)
	defer json_object_destroy(inner)
	json_object_set(&inner, "table", jstr(table, allocator))
	json_object_set(&inner, "cells", JSONArray(flatten_cells(cells, allocator)))
	json_object_set(&inner, "returning", JSONBool(false))
	if len(update_cells) > 0 {
		json_object_set(&inner, "update_cells", JSONArray(flatten_cells(update_cells, allocator)))
	}
	op := json_object_make(allocator)
	json_object_set(&op, "upsert", inner)
	ops := make([dynamic]JSONValue, allocator)
	defer free_dyn(ops)
	append(&ops, op)

	results, err := commit_txn(db, ops[:], idempotency_key, allocator)
	if err != .None_ { return JSONNull{}, err }
	if len(results) == 0 { return JSONNull{}, .None_ }
	return results[0], .None_
}

// delete removes a row by its internal row id.
delete :: proc(db: Client, table: string, row_id: i64, allocator := context.allocator) -> Mongrel_Error {
	inner := json_object_make(allocator)
	defer json_object_destroy(inner)
	json_object_set(&inner, "table", jstr(table, allocator))
	json_object_set(&inner, "row_id", JSONInteger(row_id))
	op := json_object_make(allocator)
	json_object_set(&op, "delete", inner)
	ops := make([dynamic]JSONValue, allocator)
	defer free_dyn(ops)
	append(&ops, op)
	_, err := commit_txn(db, ops[:], "", allocator)
	return err
}

// delete_by_pk removes a row by its primary-key value.
delete_by_pk :: proc(db: Client, table: string, pk: JSONValue, allocator := context.allocator) -> Mongrel_Error {
	inner := json_object_make(allocator)
	defer json_object_destroy(inner)
	json_object_set(&inner, "table", jstr(table, allocator))
	json_object_set(&inner, "pk", pk)
	op := json_object_make(allocator)
	json_object_set(&op, "delete_by_pk", inner)
	ops := make([dynamic]JSONValue, allocator)
	defer free_dyn(ops)
	append(&ops, op)
	_, err := commit_txn(db, ops[:], "", allocator)
	return err
}

// single_txn is the convenience helper for put: it builds a one-op put
// transaction (no update_cells).
single_txn :: proc(db: Client, table: string, cells: []Cell, idempotency_key: string, kind: string, allocator: mem.Allocator) -> ([]JSONValue, Mongrel_Error) {
	inner := json_object_make(allocator)
	defer json_object_destroy(inner)
	json_object_set(&inner, "table", jstr(table, allocator))
	json_object_set(&inner, "cells", JSONArray(flatten_cells(cells, allocator)))
	json_object_set(&inner, "returning", JSONBool(false))
	op := json_object_make(allocator)
	json_object_set(&op, kind, inner)
	ops := make([dynamic]JSONValue, allocator)
	defer free_dyn(ops)
	append(&ops, op)
	return commit_txn(db, ops[:], idempotency_key, allocator)
}

// ── Query ─────────────────────────────────────────────────────────────────

// QueryBuilder accumulates a single table query.
QueryBuilder :: struct {
	db:         Client,
	table:      string,
	conditions: [dynamic]QueryCondition,
	projection: [dynamic]i64,
	has_proj:   bool,
	limit_val:  i64,
	has_limit:  bool,
}

// QueryCondition is a normalized (type, params) condition pushed down to a
// native index.
QueryCondition :: struct {
	condition_type: string,
	params:         JSONObject,
}

// query starts a fluent `QueryBuilder` against `table`.
query :: proc(db: Client, table: string, allocator := context.allocator) -> QueryBuilder {
	return QueryBuilder{
		db = db,
		table = table,
		conditions = make([dynamic]QueryCondition, allocator),
		projection = make([dynamic]i64, allocator),
	}
}

// where_ appends a condition. `cond_type` names the condition (e.g. "pk",
// "column_eq", "range"); `params` is the condition payload, normalized.
where_ :: proc(qb: ^QueryBuilder, cond_type: string, params: JSONObject) -> ^QueryBuilder {
	normalized := normalize_condition(cond_type, params)
	append(&qb.conditions, QueryCondition{cond_type, normalized})
	return qb
}

// projection requests only the given column ids in each row.
projection :: proc(qb: ^QueryBuilder, column_ids: []i64) -> ^QueryBuilder {
	clear(&qb.projection)
	for id in column_ids { append(&qb.projection, id) }
	qb.has_proj = true
	return qb
}

// limit_ caps the number of rows returned.
limit_ :: proc(qb: ^QueryBuilder, row_limit: i64) -> ^QueryBuilder {
	qb.limit_val = row_limit
	qb.has_limit = true
	return qb
}

// execute builds the request, POSTs it to `/kit/query`, decodes the result
// set, and returns the rows.
execute :: proc(qb: ^QueryBuilder, allocator := context.allocator) -> ([]JSONValue, Mongrel_Error) {
	root := json_object_make(allocator)
	defer json_object_destroy(root)
	json_object_set(&root, "table", jstr(qb.table, allocator))
	if len(qb.conditions) > 0 {
		conds := make([dynamic]JSONValue, 0, len(qb.conditions), allocator)
		defer free_dyn(conds)
		for c in qb.conditions {
			cond_obj := json_object_make(allocator)
			json_object_set(&cond_obj, c.condition_type, c.params)
			append(&conds, cond_obj)
		}
		json_object_set(&root, "conditions", conds)
	}
	if qb.has_proj {
		proj := make([dynamic]JSONValue, 0, len(qb.projection), allocator)
		defer free_dyn(proj)
		for id in qb.projection { append(&proj, JSONInteger(id)) }
		json_object_set(&root, "projection", proj)
	}
	if qb.has_limit {
		json_object_set(&root, "limit", JSONInteger(qb.limit_val))
	}

	payload := root
	body, err := raw_request(qb.db, allocator, .POST, "/kit/query", payload)
	if err != .None_ { return nil, err }
	defer free_slice(body, allocator)

	value, jerr := json_parse(body, allocator)
	if jerr != "" { return nil, .Json }
	defer json_destroy(value, allocator)

	o, ok := value.(JSONObject)
	if !ok { return nil, .Json }
	rows_any, has := json_object_get(o, "rows")
	if !has { return nil, .Json }
	rows, ok2 := rows_any.(JSONArray)
	if !ok2 { return nil, .Json }
	return rows[:], .None_
}

// free_query_builder releases the dynamic allocations held by a QueryBuilder.
free_query_builder :: proc(qb: ^QueryBuilder) {
	free_dyn(qb.conditions)
	free_dyn(qb.projection)
}

// ── Transactions ──────────────────────────────────────────────────────────

// Transaction buffers a sequence of operations and flushes them atomically in
// a single `/kit/txn` request.
Transaction :: struct {
	db:        Client,
	ops:       [dynamic]JSONValue,
	committed: bool,
}

// begin starts a new batch transaction.
begin :: proc(db: Client, allocator := context.allocator) -> Transaction {
	return Transaction{db = db, ops = make([dynamic]JSONValue, allocator)}
}

// txn_put stages an insert on the transaction.
txn_put :: proc(t: ^Transaction, table: string, cells: []Cell, returning: bool, allocator := context.allocator) -> (^Transaction, Mongrel_Error) {
	if t.committed { return nil, .Already_Committed }
	inner := json_object_make(allocator)
	json_object_set(&inner, "table", jstr(table, allocator))
	json_object_set(&inner, "cells", JSONArray(flatten_cells(cells, allocator)))
	json_object_set(&inner, "returning", JSONBool(returning))
	op := json_object_make(allocator)
	json_object_set(&op, "put", inner)
	append(&t.ops, op)
	return t, .None_
}

// txn_delete stages a delete by row id.
txn_delete :: proc(t: ^Transaction, table: string, row_id: i64, allocator := context.allocator) -> (^Transaction, Mongrel_Error) {
	if t.committed { return nil, .Already_Committed }
	inner := json_object_make(allocator)
	json_object_set(&inner, "table", jstr(table, allocator))
	json_object_set(&inner, "row_id", JSONInteger(row_id))
	op := json_object_make(allocator)
	json_object_set(&op, "delete", inner)
	append(&t.ops, op)
	return t, .None_
}

// txn_delete_by_pk stages a delete by primary key.
txn_delete_by_pk :: proc(t: ^Transaction, table: string, pk: JSONValue, allocator := context.allocator) -> (^Transaction, Mongrel_Error) {
	if t.committed { return nil, .Already_Committed }
	inner := json_object_make(allocator)
	json_object_set(&inner, "table", jstr(table, allocator))
	json_object_set(&inner, "pk", pk)
	op := json_object_make(allocator)
	json_object_set(&op, "delete_by_pk", inner)
	append(&t.ops, op)
	return t, .None_
}

// txn_count returns the number of staged operations.
txn_count :: proc(t: Transaction) -> int {
	return len(t.ops)
}

// commit sends a batch of staged operations atomically to `/kit/txn` and
// returns the per-operation results array.
commit :: proc(t: ^Transaction, idempotency_key: string, allocator := context.allocator) -> ([]JSONValue, Mongrel_Error) {
	if t.committed { return nil, .Already_Committed }
	if len(t.ops) == 0 {
		t.committed = true
		return nil, .None_
	}
	results, err := commit_txn(t.db, t.ops[:], idempotency_key, allocator)
	if err != .None_ { return nil, err }
	t.committed = true
	return results, .None_
}

// rollback discards all locally staged operations.
rollback :: proc(t: ^Transaction) -> Mongrel_Error {
	if t.committed { return .Already_Committed }
	t.committed = true
	clear(&t.ops)
	return .None_
}

// free_transaction releases the dynamic allocations held by a Transaction.
free_transaction :: proc(t: ^Transaction) {
	free_dyn(t.ops)
}

// ── SQL ───────────────────────────────────────────────────────────────────

// sql executes a SQL statement via the `/sql` endpoint, requesting JSON
// output. The server returns a JSON array of row objects keyed by column
// name. For statements that yield no rows (DDL/DML), an empty slice is
// returned.
sql :: proc(db: Client, sql_text: string, allocator := context.allocator) -> ([]JSONValue, Mongrel_Error) {
	root := json_object_make(allocator)
	defer json_object_destroy(root)
	json_object_set(&root, "sql", jstr(sql_text, allocator))
	json_object_set(&root, "format", jstr("json", allocator))

	body, err := raw_request(db, allocator, .POST, "/sql", root)
	if err != .None_ { return nil, err }
	defer free_slice(body, allocator)

	trimmed := strings.trim_space(string(body))
	if trimmed == "" { return nil, .None_ }
	// JSON format requested; a leading '{' is a single object (e.g. an error
	// envelope), not a row set, so return an empty slice. A '[' begins the
	// row array to decode.
	if trimmed[0] != '[' { return nil, .None_ }

	value, jerr := json_parse(body, allocator)
	if jerr != "" { return nil, .Json }
	defer json_destroy(value, allocator)
	arr, ok := value.(JSONArray)
	if !ok { return nil, .None_ }
	return arr[:], .None_
}

// ── Schema ────────────────────────────────────────────────────────────────

// schema returns the full schema catalog: a map of table-name to descriptor.
schema :: proc(db: Client, allocator := context.allocator) -> (map[string]JSONValue, Mongrel_Error) {
	body, err := raw_request(db, allocator, .GET, "/kit/schema", nil)
	if err != .None_ { return nil, err }
	defer free_slice(body, allocator)

	value, jerr := json_parse(body, allocator)
	if jerr != "" { return nil, .Json }
	defer json_destroy(value, allocator)

	o, ok := value.(JSONObject)
	if !ok { return nil, .Json }
	tables_any, has := json_object_get(o, "tables")
	if !has { return map[string]JSONValue{}, .None_ }
	tables, ok2 := tables_any.(JSONObject)
	if !ok2 { return nil, .Json }
	out := make(map[string]JSONValue, len(tables.keys), allocator)
	for i in 0..<len(tables.keys) {
		out[tables.keys[i]] = tables.values[i]
	}
	return out, .None_
}

// schema_for returns the descriptor for a single table.
schema_for :: proc(db: Client, table: string, allocator := context.allocator) -> (JSONValue, Mongrel_Error) {
	escaped := url_path_escape(table, allocator)
	defer if escaped != table { free_string(escaped, allocator) }
	path := fmt.tprintf("/kit/schema/%s", escaped)
	defer free_string(path)
	body, err := raw_request(db, allocator, .GET, path, nil)
	if err != .None_ { return nil, err }
	defer free_slice(body, allocator)

	value, jerr := json_parse(body, allocator)
	if jerr != "" { return nil, .Json }
	return value, .None_
}

// ── Internal HTTP plumbing ────────────────────────────────────────────────

// commit_txn sends a batch of operations and returns the decoded results.
commit_txn :: proc(db: Client, ops: []JSONValue, idempotency_key: string, allocator := context.allocator) -> ([]JSONValue, Mongrel_Error) {
	ops_dyn := make([dynamic]JSONValue, 0, len(ops), allocator)
	defer free_dyn(ops_dyn)
	for op in ops { append(&ops_dyn, op) }

	root := json_object_make(allocator)
	defer json_object_destroy(root)
	json_object_set(&root, "ops", ops_dyn)
	if idempotency_key != "" {
		json_object_set(&root, "idempotency_key", jstr(idempotency_key, allocator))
	}

	body, err := raw_request(db, allocator, .POST, "/kit/txn", root)
	if err != .None_ { return nil, err }
	defer free_slice(body, allocator)

	value, jerr := json_parse(body, allocator)
	if jerr != "" { return nil, .Json }
	defer json_destroy(value, allocator)

	o, ok := value.(JSONObject)
	if !ok { return nil, .Json }
	results_any, has := json_object_get(o, "results")
	if !has { return nil, .None_ }
	results, ok2 := results_any.(JSONArray)
	if !ok2 { return nil, .Json }
	return results[:], .None_
}

// raw_request builds and runs one request against the daemon via libcurl (C
// FFI). Non-2xx responses are mapped to typed errors via `map_status`.
raw_request :: proc(db: Client, allocator: mem.Allocator, method: Method, path: string, payload: Maybe(JSONValue)) -> ([]u8, Mongrel_Error) {
	context.allocator = allocator
	url := fmt.tprintf("%s/%s", db.base_url, strings.trim_left(path, "/"))
	defer free_string(url)

	body_str := ""
	has_body := false
	if payload != nil {
		p := payload.?
		body_str = json_to_string(p, allocator)
		has_body = true
	}
	defer if has_body { free_string(body_str, allocator) }

	// CRLF validation: guard against any caller-supplied content sneaking a
	// CR/LF through the auth header (request smuggling).
	if db.token != "" && (strings.contains(db.token, "\r") || strings.contains(db.token, "\n")) {
		return nil, .Query
	}
	if db.username != "" && (strings.contains(db.username, "\r") || strings.contains(db.username, "\n")) {
		return nil, .Query
	}

	resp_body, status, ok := curl_perform(
		url,
		method,
		has_body,
		body_str,
		db.token,
		db.username,
		db.password,
		allocator,
	)
	if !ok {
		return nil, .Http
	}

	if u64(len(resp_body)) > max_response_bytes {
		free_slice(resp_body, allocator)
		return nil, .Response_Too_Large
	}

	if status < 200 || status >= 300 {
		free_slice(resp_body, allocator)
		return nil, map_status(status)
	}

	// Transfer ownership to the caller.
	return resp_body, .None_
}

// map_status maps an HTTP status code to a typed `Mongrel_Error`.
map_status :: proc(code: int) -> Mongrel_Error {
	switch {
	case code == 300, code == 301, code == 302, code == 303, code == 304, code == 307, code == 308:
		return .Http
	case code == 401, code == 403:
		return .Auth
	case code == 402, code == 409:
		return .Conflict
	case code == 404:
		return .Not_Found
	case code >= 500 && code <= 599:
		return .Http
	case:
		return .Query
	}
}

// ── Cell / column helpers ─────────────────────────────────────────────────

// flatten_cells converts a slice of cells to the server's flat
// `[col_id, value, col_id, value, ...]` JSON array.
flatten_cells :: proc(cells: []Cell, allocator := context.allocator) -> [dynamic]JSONValue {
	flat := make([dynamic]JSONValue, 0, len(cells) * 2, allocator)
	for c in cells {
		append(&flat, JSONInteger(c.id))
		append(&flat, c.value)
	}
	return flat
}

// column_to_value serializes a single `Column` into the JSON object the
// daemon's `/kit/create_table` extractor recognizes.
column_to_value :: proc(c: Column, allocator := context.allocator) -> JSONValue {
	obj := json_object_make(allocator)
	json_object_set(&obj, "id", JSONInteger(c.id))
	json_object_set(&obj, "name", jstr(c.name, allocator))
	json_object_set(&obj, "ty", jstr(c.ty, allocator))
	json_object_set(&obj, "primary_key", JSONBool(c.primary_key))
	json_object_set(&obj, "nullable", JSONBool(c.nullable))
	if c.has_enum && len(c.enum_variants) > 0 {
		arr := make([dynamic]JSONValue, 0, len(c.enum_variants), allocator)
		for v in c.enum_variants { append(&arr, jstr(v, allocator)) }
		json_object_set(&obj, "enum_variants", arr)
	}
	if c.has_default_expr && c.default_expr != "" {
		json_object_set(&obj, "default_expr", jstr(c.default_expr, allocator))
	} else if c.has_default_scalar {
		json_object_set(&obj, "default_value", c.default_scalar)
	} else if c.has_default && c.default_value != "" {
		json_object_set(&obj, "default_value", jstr(c.default_value, allocator))
	}
	return obj
}

// column_to_json_string serializes a `Column` to a compact JSON string.
// Exposed so wire-shape conformance tests can assert the produced body
// without a live daemon.
column_to_json_string :: proc(c: Column, allocator := context.allocator) -> string {
	v := column_to_value(c, allocator)
	defer json_destroy(v, allocator)
	return json_to_string(v, allocator)
}

// normalize_condition rewrites user-facing param names to the engine's
// canonical condition fields.
normalize_condition :: proc(cond_type: string, params: JSONObject) -> JSONObject {
	fm_contains := cond_type == "fm_contains" || cond_type == "fm_contains_all"
	out := json_object_make(context.allocator)
	for i in 0..<json_object_len(params) {
		key := params.keys[i]
		name := key
		switch key {
		case "column":
			name = "column_id"
		case "min":
			name = "lo"
		case "max":
			name = "hi"
		case "min_inclusive":
			name = "lo_inclusive"
		case "max_inclusive":
			name = "hi_inclusive"
		case:
			if fm_contains && key == "value" { name = "pattern" }
		}
		json_object_set(&out, name, params.values[i])
	}
	return out
}

// ── URL escaping ──────────────────────────────────────────────────────────

// url_path_escape percent-escapes a path segment so table names containing
// '/', '?', '#', or spaces cannot inject extra segments or break routing.
url_path_escape :: proc(seg: string, allocator := context.allocator) -> string {
	needs_escape := false
	for b in transmute([]u8)seg {
		if !is_unreserved(b) {
			needs_escape = true
			break
		}
	}
	if !needs_escape { return seg }

	sb := strings.builder_make(allocator)
	hex := "0123456789ABCDEF"
	for b in transmute([]u8)seg {
		if is_unreserved(b) {
			strings.write_byte(&sb, b)
		} else {
			strings.write_byte(&sb, '%')
			strings.write_byte(&sb, hex[b >> 4])
			strings.write_byte(&sb, hex[b & 0x0f])
		}
	}
	view := strings.to_string(sb)
	out, _ := strings.clone(view, allocator)
	free_dyn(sb.buf)
	return out
}

is_unreserved :: proc(b: u8) -> bool {
	is_upper := b >= 'A' && b <= 'Z'
	is_lower := b >= 'a' && b <= 'z'
	is_digit := b >= '0' && b <= '9'
	is_dash := b == '-'
	is_under := b == '_'
	is_dot := b == '.'
	is_tilde := b == '~'
	return is_upper || is_lower || is_digit || is_dash || is_under || is_dot || is_tilde
}

// ── Value constructors ────────────────────────────────────────────────────

int_value :: proc(i: i64) -> JSONValue { return JSONInteger(i) }
float_value :: proc(f: f64) -> JSONValue { return JSONFloat(f) }
bool_value :: proc(b: bool) -> JSONValue { return JSONBool(b) }
null_value :: proc() -> JSONValue { return JSONNull{} }

// string_value clones `s` into the allocator so the resulting JSONValue owns
// its string storage and json_destroy can free it safely. Never embed a
// string literal or a borrowed slice directly in a JSONValue: json_destroy
// would attempt to free non-heap memory. Use this helper (or jstr below) for
// any string that ends up inside a JSONValue tree.
string_value :: proc(s: string, allocator := context.allocator) -> JSONValue {
	cs, _ := strings.clone(s, allocator)
	return JSONString(cs)
}

// jstr is the internal alias used by the request builders to clone a string
// field into the allocator before embedding it in a JSONValue. Keeping every
// JSONString in a built value heap-owned lets json_destroy uniformly free the
// whole tree without double-frees or freeing non-heap memory.
jstr :: proc(s: string, allocator := context.allocator) -> JSONString {
	cs, _ := strings.clone(s, allocator)
	return JSONString(cs)
}
