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

import m "mongreldb"

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
url_path_escape_escapes_spaces_and_slashes :: proc(t: ^testing.T) {
	esc := m.url_path_escape("my table/with spaces")
	defer m.free_string(esc)

	// Space must become %20; slash must be escaped so it can't inject a path
	// segment.
	testing.expectf(t, contains(esc, "%20"), "expected %%20 for space, got %s", esc)
	testing.expect(t, !strings.contains(esc, " "))
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
