// Wire-shape conformance tests for the mongreldb Odin client.
//
// These tests are pure (no daemon required) - they serialize a `Column` via
// `column_to_json_string`, stringify it, and assert the exact keys + values
// appear in the outgoing JSON body. They guard the ergonomic extension that
// adds `enum_variants` and `default_value` keys to the per-column payload that
// `/kit/create_table` accepts. A future regression that drops either key would
// silently break user schemas, so the wire shape is asserted here rather than
// only on the server side.
//
// They also exercise the URL-path escaper (so table names with spaces or
// slashes cannot inject extra path segments) and the JSON parser/serializer
// round-trip.

package mongreldb_test

import "core:fmt"
import "core:strings"
import "core:testing"

import m "mdb:mongreldb"

// contains is a local helper since the assertion reads more clearly with it
// than with the raw strings.has_prefix/suffix helpers.
contains :: proc(haystack, needle: string) -> bool {
	return strings.contains(haystack, needle)
}

@(test)
column_to_json_emits_enum_and_default :: proc(t: ^testing.T) {
	col := m.Column{
		id = 1,
		name = "color",
		ty = "string",
		primary_key = false,
		nullable = false,
		has_enum = true,
		enum_variants = make([dynamic]string, 0, 2),
		has_default = true,
		default_value = "a",
	}
	append(&col.enum_variants, "a")
	append(&col.enum_variants, "b")
	defer delete(col.enum_variants)

	s := m.column_to_json_string(col)
	defer m.free_string(s)

	testing.expectf(t, contains(s, "\"enum_variants\":[\"a\",\"b\"]"),
		"expected enum_variants array, got %s", s)
	testing.expectf(t, contains(s, "\"default_value\":\"a\""),
		"expected default_value, got %s", s)
}

@(test)
column_to_json_omits_absent_optional_keys :: proc(t: ^testing.T) {
	// No enum/default supplied - both keys must be absent so the wire shape
	// matches the pre-extension baseline exactly.
	col := m.Column{
		id = 2,
		name = "amount",
		ty = "int64",
		primary_key = true,
		nullable = false,
	}

	s := m.column_to_json_string(col)
	defer m.free_string(s)

	testing.expect(t, !contains(s, "enum_variants"))
	testing.expect(t, !contains(s, "default_value"))
	testing.expectf(t, contains(s, "\"primary_key\":true"),
		"expected primary_key:true, got %s", s)
	testing.expectf(t, contains(s, "\"nullable\":false"),
		"expected nullable:false, got %s", s)
}

@(test)
column_to_json_omits_empty_enum :: proc(t: ^testing.T) {
	// An explicit empty slice should not be emitted - null and empty are
	// treated the same on the wire to keep schemas identical to the no-key
	// case.
	col := m.Column{
		id = 3,
		name = "label",
		ty = "string",
		has_enum = true,
		enum_variants = make([dynamic]string),
		has_default = true,
		default_value = "x",
	}
	defer delete(col.enum_variants)

	s := m.column_to_json_string(col)
	defer m.free_string(s)

	testing.expect(t, !contains(s, "enum_variants"))
	testing.expectf(t, contains(s, "\"default_value\":\"x\""),
		"expected default_value:x, got %s", s)
}

@(test)
column_to_json_emits_numeric_default :: proc(t: ^testing.T) {
	col := m.Column{
		id = 4,
		name = "retries",
		ty = "int64",
		has_default_scalar = true,
		default_scalar = m.int_value(3),
	}
	s := m.column_to_json_string(col)
	defer m.free_string(s)
	testing.expectf(t, contains(s, "\"default_value\":3"),
		"expected numeric default_value, got %s", s)
}

@(test)
column_to_json_emits_bool_and_null_defaults :: proc(t: ^testing.T) {
	bool_col := m.Column{id = 5, name = "enabled", ty = "bool", has_default_scalar = true, default_scalar = m.bool_value(true)}
	null_col := m.Column{id = 6, name = "optional", ty = "string", has_default_scalar = true, default_scalar = m.null_value()}
	bool_json := m.column_to_json_string(bool_col)
	null_json := m.column_to_json_string(null_col)
	defer m.free_string(bool_json)
	defer m.free_string(null_json)
	testing.expect(t, contains(bool_json, "\"default_value\":true"))
	testing.expect(t, contains(null_json, "\"default_value\":null"))
}

@(test)
column_to_json_emits_dynamic_default_expr :: proc(t: ^testing.T) {
	col := m.Column{
		id = 7,
		name = "created_at",
		ty = "timestamp",
		has_default = true,
		default_value = "legacy",
		has_default_scalar = true,
		default_scalar = m.int_value(3),
		has_default_expr = true,
		default_expr = "now",
	}
	s := m.column_to_json_string(col)
	defer m.free_string(s)
	testing.expectf(t, contains(s, "\"default_expr\":\"now\""),
		"expected dynamic default_expr, got %s", s)
	testing.expect(t, !contains(s, "default_value"))
}

@(test)
column_to_json_full_static_default_matrix :: proc(t: ^testing.T) {
	// The full static-default matrix: string, integer, boolean, explicit null,
	// literal "now" and "uuid" strings, and default_expr. Each must preserve its
	// JSON type on the wire and default_expr must suppress any default_value.
	string_col := m.Column{
		id = 10, name = "status", ty = "varchar",
		has_default = true, default_value = "draft",
	}
	number_col := m.Column{
		id = 11, name = "retries", ty = "int64",
		has_default_scalar = true, default_scalar = m.int_value(7),
	}
	bool_col := m.Column{
		id = 12, name = "enabled", ty = "bool",
		has_default_scalar = true, default_scalar = m.bool_value(true),
	}
	null_col := m.Column{
		id = 13, name = "optional", ty = "varchar",
		has_default_scalar = true, default_scalar = m.null_value(),
	}
	literal_now_col := m.Column{
		id = 14, name = "tag", ty = "varchar",
		has_default = true, default_value = "now",
	}
	literal_uuid_col := m.Column{
		id = 15, name = "uuid_col", ty = "varchar",
		has_default = true, default_value = "uuid",
	}
	expr_col := m.Column{
		id = 16, name = "created_at", ty = "timestamp_nanos",
		has_default_expr = true, default_expr = "now",
	}

	string_json := m.column_to_json_string(string_col)
	number_json := m.column_to_json_string(number_col)
	bool_json := m.column_to_json_string(bool_col)
	null_json := m.column_to_json_string(null_col)
	literal_now_json := m.column_to_json_string(literal_now_col)
	literal_uuid_json := m.column_to_json_string(literal_uuid_col)
	expr_json := m.column_to_json_string(expr_col)
	defer m.free_string(string_json)
	defer m.free_string(number_json)
	defer m.free_string(bool_json)
	defer m.free_string(null_json)
	defer m.free_string(literal_now_json)
	defer m.free_string(literal_uuid_json)
	defer m.free_string(expr_json)

	assert_default :: proc(t: ^testing.T, json_str, key: string, expected: m.JSONValue) {
		parsed, perr := m.json_parse(transmute([]u8)json_str)
		if perr != "" {
			testing.fail(t)
			return
		}
		defer m.json_destroy(parsed)
		o, ok := parsed.(m.JSONObject)
		testing.expect(t, ok)
		if !ok { return }
		v, has := m.json_object_get(o, key)
		testing.expectf(t, has, "missing %s in %s", key, json_str)
		if !has { return }
		switch exp in expected {
		case m.JSONNull:
			_, is_null := v.(m.JSONNull)
			testing.expectf(t, is_null, "expected null default in %s", json_str)
		case m.JSONInteger:
			got, is_int := v.(m.JSONInteger)
			testing.expectf(t, is_int && i64(got) == i64(exp), "expected integer %d in %s", i64(exp), json_str)
		case m.JSONBool:
			got, is_bool := v.(m.JSONBool)
			testing.expectf(t, is_bool && bool(got) == bool(exp), "expected bool %v in %s", bool(exp), json_str)
		case m.JSONString:
			got, is_str := v.(m.JSONString)
			testing.expectf(t, is_str && string(got) == string(exp), "expected string %s in %s", string(exp), json_str)
		}
	}

	assert_default(t, string_json, "default_value", m.JSONString("draft"))
	assert_default(t, number_json, "default_value", m.JSONInteger(7))
	assert_default(t, bool_json, "default_value", m.JSONBool(true))
	assert_default(t, null_json, "default_value", m.JSONNull{})
	assert_default(t, literal_now_json, "default_value", m.JSONString("now"))
	assert_default(t, literal_uuid_json, "default_value", m.JSONString("uuid"))
	assert_default(t, expr_json, "default_expr", m.JSONString("now"))

	// default_expr must suppress any default_value/default_scalar.
	parsed_expr, perr := m.json_parse(transmute([]u8)expr_json)
	defer m.json_destroy(parsed_expr)
	if perr == "" {
		o, ok := parsed_expr.(m.JSONObject)
		if ok {
			_, has_default := m.json_object_get(o, "default_value")
			testing.expectf(t, !has_default, "default_expr must suppress default_value in %s", expr_json)
		}
	}
}

@(test)
history_retention_payload_emits_exact_key :: proc(t: ^testing.T) {
	payload := m.history_retention_payload(42)
	defer m.json_object_destroy(payload)
	wire := m.json_to_string(m.JSONObject(payload))
	defer m.free_string(wire)

	parsed, perr := m.json_parse(transmute([]u8)wire)
	defer m.json_destroy(parsed)
	testing.expectf(t, perr == "", "payload parse error: %s", perr)
	if perr != "" { return }
	o, ok := parsed.(m.JSONObject)
	testing.expect(t, ok)
	if !ok { return }
	epochs_v, has := m.json_object_get(o, "history_retention_epochs")
	testing.expect(t, has)
	if has {
		epochs, is_int := epochs_v.(m.JSONInteger)
		testing.expectf(t, is_int && i64(epochs) == 42, "expected 42, got %v", epochs_v)
	}
	_, has_earliest := m.json_object_get(o, "earliest_retained_epoch")
	testing.expectf(t, !has_earliest, "payload must not contain earliest_retained_epoch")
}

@(test)
parse_history_retention_rejects_missing_and_malformed_keys :: proc(t: ^testing.T) {
	// Full response decodes both u64 fields.
	full := m.json_object_make()
	defer m.json_object_destroy(full)
	m.json_object_set(&full, "history_retention_epochs", m.int_value(100))
	m.json_object_set(&full, "earliest_retained_epoch", m.int_value(7))
	hr, err := m.parse_history_retention(m.JSONObject(full))
	testing.expectf(t, err == .None_, "unexpected error: %s", m.mongrel_error_string(err))
	testing.expect(t, hr.history_retention_epochs == 100)
	testing.expect(t, hr.earliest_retained_epoch == 7)

	// Missing either key must fail with .Json.
	missing_earliest := m.json_object_make()
	defer m.json_object_destroy(missing_earliest)
	m.json_object_set(&missing_earliest, "history_retention_epochs", m.int_value(100))
	_, err2 := m.parse_history_retention(m.JSONObject(missing_earliest))
	testing.expectf(t, err2 == .Json, "expected Json error for missing earliest, got %s", m.mongrel_error_string(err2))

	missing_window := m.json_object_make()
	defer m.json_object_destroy(missing_window)
	m.json_object_set(&missing_window, "earliest_retained_epoch", m.int_value(7))
	_, err3 := m.parse_history_retention(m.JSONObject(missing_window))
	testing.expectf(t, err3 == .Json, "expected Json error for missing window, got %s", m.mongrel_error_string(err3))

	// Non-object or wrong-typed value must fail.
	_, err4 := m.parse_history_retention(m.JSONString("bad"))
	testing.expectf(t, err4 == .Json, "expected Json error for non-object, got %s", m.mongrel_error_string(err4))

	string_value := m.json_object_make()
	defer m.json_object_destroy(string_value)
	m.json_object_set(&string_value, "history_retention_epochs", m.string_value("100"))
	m.json_object_set(&string_value, "earliest_retained_epoch", m.int_value(7))
	_, err5 := m.parse_history_retention(m.JSONObject(string_value))
	testing.expectf(t, err5 == .Json, "expected Json error for string value, got %s", m.mongrel_error_string(err5))

	negative := m.json_object_make()
	defer m.json_object_destroy(negative)
	m.json_object_set(&negative, "history_retention_epochs", m.int_value(-1))
	m.json_object_set(&negative, "earliest_retained_epoch", m.int_value(7))
	_, err6 := m.parse_history_retention(m.JSONObject(negative))
	testing.expectf(t, err6 == .Json, "expected Json error for negative value, got %s", m.mongrel_error_string(err6))
}

@(test)
create_table_payload_emits_constraints :: proc(t: ^testing.T) {
	// The constraints branch must survive payload construction even when the
	// object carries a real checks array. The HTTP path uses the same helper.
	constraints := m.json_object_make()
	check := m.json_object_make()
	m.json_object_set(&check, "id", m.int_value(1))
	m.json_object_set(&check, "name", m.string_value("id_present"))
	checks := make([dynamic]m.JSONValue)
	append(&checks, check)
	m.json_object_set(&constraints, "checks", m.JSONArray(checks))
	obj, cols := m.create_table_payload("events", nil, constraints, true)
	defer m.json_object_destroy(obj)
	defer m.json_destroy(m.JSONArray(cols))
	wire := m.json_to_string(obj)
	defer m.free_string(wire)
	testing.expectf(t, contains(wire, "\"constraints\":{\"checks\":["),
		"expected top-level constraints.checks, got %s", wire)
	m.json_destroy(constraints)
}

@(test)
url_path_escape_escapes_spaces_and_slashes :: proc(t: ^testing.T) {
	esc := m.url_path_escape("my table/with spaces")
	defer m.free_string(esc)

	// Space must become %20; slash must be escaped so it can't inject a path
	// segment.
	testing.expectf(t, contains(esc, "%20"), "expected %%20 for space, got %s", esc)
	testing.expect(t, !strings.contains(esc, " "))
	testing.expect(t, !strings.contains(esc, "/"))
}

@(test)
url_path_escape_passes_unreserved_through :: proc(t: ^testing.T) {
	// Unreserved characters (letters, digits, -, _, ., ~) pass through
	// unchanged, so the escaped string shares storage with the input and is
	// not heap-allocated (do NOT free it).
	esc := m.url_path_escape("table_ABC-123.~")
	testing.expect(t, esc == "table_ABC-123.~")
}

@(test)
json_round_trip_preserves_values :: proc(t: ^testing.T) {
	o := m.json_object_make()
	defer m.json_object_destroy(o)
	m.json_object_set(&o, "name", m.string_value("hello"))
	m.json_object_set(&o, "count", m.int_value(42))
	m.json_object_set(&o, "ratio", m.float_value(3.14))
	m.json_object_set(&o, "flag", m.bool_value(true))

	serialized := m.json_to_string(o)
	defer m.free_string(serialized)

	parsed, err := m.json_parse(transmute([]u8)serialized)
	if err != "" {
		fmt.eprintf("parse error: %s\n", err)
		testing.fail(t)
		return
	}
	defer m.json_destroy(parsed)

	po, ok := parsed.(m.JSONObject)
	testing.expect(t, ok)

	name_v, _ := m.json_object_get(po, "name")
	name, _ := name_v.(m.JSONString)
	count_v, _ := m.json_object_get(po, "count")
	count, _ := count_v.(m.JSONInteger)
	testing.expectf(t, string(name) == "hello", "name round-trip: %s", string(name))
	testing.expectf(t, i64(count) == 42, "count round-trip: %d", i64(count))
}
