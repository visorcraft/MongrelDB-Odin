// A small, self-contained JSON value type, serializer, and parser for the
// mongreldb Odin client.
//
// This avoids depending on any particular version of `core:encoding/json`'s
// polymorphic union, keeping the client self-contained (Odin has no package
// manager, so a local, version-stable JSON layer is the safest choice). All
// allocations come from the caller's `context.allocator`.
//
// The parser is a strict recursive-descent JSON decoder sufficient for the
// daemon's responses (objects, arrays, strings, numbers, booleans, null).

package mongreldb

import "core:fmt"
import "core:mem"
import "core:strings"
import "base:runtime"

// free_dyn / free_slice / free_string release heap storage allocated through
// `context.allocator`. They reference the builtin `delete` overloads directly
// (by their fully-qualified names) so the package's own `delete` CRUD method
// (which shadows the unqualified `delete` name) cannot intercept these calls.
free_dyn :: proc(array: $T/[dynamic]$E, loc := #caller_location) {
	runtime.delete_dynamic_array(array, loc)
}

free_slice :: proc(s: $T/[]$E, allocator := context.allocator, loc := #caller_location) {
	runtime.delete_slice(s, allocator, loc)
}

free_string :: proc(s: string, allocator := context.allocator, loc := #caller_location) {
	runtime.delete_string(s, allocator, loc)
}

free_cstring :: proc(s: cstring, allocator := context.allocator, loc := #caller_location) {
	runtime.delete_cstring(s, allocator, loc)
}

// JSONValue is a dynamic JSON value. Object key order is preserved by the
// parser (via a small ordered map); the serializer emits keys in insertion
// order.
JSONValue :: union {
	JSONNull,
	JSONBool,
	JSONInteger,
	JSONFloat,
	JSONString,
	JSONArray,
	JSONObject,
}

JSONNull :: struct{}
JSONBool :: bool
JSONInteger :: i64
JSONFloat :: f64
JSONString :: string

// JSONArray is an ordered list of values (backed by a dynamic array).
JSONArray :: [dynamic]JSONValue

// JSONObject is an insertion-ordered map of string -> value. Built on two
// parallel slices: keys and values. Lookups are linear; this is fine for the
// modest object sizes the daemon returns.
JSONObject :: struct {
	keys:   [dynamic]string,
	values: [dynamic]JSONValue,
}

// json_object_make creates an empty object.
json_object_make :: proc(allocator := context.allocator) -> JSONObject {
	return {
		keys = make([dynamic]string, allocator),
		values = make([dynamic]JSONValue, allocator),
	}
}

// json_object_set sets `key` to `value`, preserving insertion order. If the
// key already exists, its value is replaced in place. The object takes
// ownership of a cloned copy of `key`; callers may pass string literals.
json_object_set :: proc(o: ^JSONObject, key: string, value: JSONValue, allocator := context.allocator) {
	for i in 0..<len(o.keys) {
		if o.keys[i] == key {
			json_destroy(o.values[i], allocator)
			o.values[i] = value
			return
		}
	}
	k, _ := strings.clone(key, allocator)
	append(&o.keys, k)
	append(&o.values, value)
}

// json_object_get looks up `key`, returning the value and whether it existed.
json_object_get :: proc(o: JSONObject, key: string) -> (JSONValue, bool) {
	for i in 0..<len(o.keys) {
		if o.keys[i] == key {
			return o.values[i], true
		}
	}
	return nil, false
}

// json_object_len returns the number of keys.
json_object_len :: proc(o: JSONObject) -> int {
	return len(o.keys)
}

// json_object_destroy releases the object's dynamic storage, including the
// cloned key strings. Does NOT free nested values (callers own those).
json_object_destroy :: proc(o: JSONObject, allocator := context.allocator) {
	for k in o.keys { free_string(k, allocator) }
	free_dyn(o.keys)
	free_dyn(o.values)
}

// json_destroy recursively releases a value's dynamic storage.
json_destroy :: proc(v: JSONValue, allocator := context.allocator) {
	#partial switch val in v {
	case JSONArray:
		for item in val {
			json_destroy(item, allocator)
		}
		free_dyn(val)
	case JSONObject:
		for i in 0..<len(val.keys) {
			json_destroy(val.values[i], allocator)
		}
		json_object_destroy(val, allocator)
	case JSONString:
		// Strings are slices; only free if the caller cloned them. We assume
		// parser-produced strings are owned and free them here. Caller-built
		// string literals (not heap) must not be passed through json_destroy;
		// the public API clones into the allocator before nesting.
		free_string(val, allocator)
	case:
		// scalars - nothing to free
	}
}

// json_clone recursively deep-copies a JSON value. The returned value owns all
// of its dynamic storage in `allocator` and can be destroyed independently.
json_clone :: proc(v: JSONValue, allocator := context.allocator) -> JSONValue {
	#partial switch val in v {
	case JSONArray:
		out := make([dynamic]JSONValue, 0, len(val), allocator)
		for item in val {
			append(&out, json_clone(item, allocator))
		}
		return JSONArray(out)
	case JSONObject:
		out := json_object_make(allocator)
		for i in 0..<len(val.keys) {
			cloned := json_clone(val.values[i], allocator)
			json_object_set(&out, val.keys[i], cloned, allocator)
		}
		return out
	case JSONString:
		s, _ := strings.clone(string(val), allocator)
		return JSONString(s)
	case:
		return v
	}
}

// ── Serialization ─────────────────────────────────────────────────────────

// json_to_string serializes a value to a compact JSON string. The returned
// string is owned by the caller (free with `delete`).
json_to_string :: proc(v: JSONValue, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	json_write(&sb, v, allocator)
	// to_string shares the builder's buffer; clone BEFORE freeing the buffer
	// so the clone reads live memory and the caller owns an independent copy.
	view := strings.to_string(sb)
	out, _ := strings.clone(view, allocator)
	free_dyn(sb.buf)
	return out
}

json_write :: proc(sb: ^strings.Builder, v: JSONValue, allocator := context.allocator) {
	#partial switch val in v {
	case JSONNull:
		strings.write_string(sb, "null")
	case JSONBool:
		strings.write_string(sb, val ? "true" : "false")
	case JSONInteger:
		strings.write_string(sb, fmt.tprintf("%d", val))
	case JSONFloat:
		strings.write_string(sb, fmt.tprintf("%g", val))
	case JSONString:
		json_write_string(sb, val)
	case JSONArray:
		strings.write_byte(sb, '[')
		for i in 0..<len(val) {
			if i > 0 { strings.write_byte(sb, ',') }
			json_write(sb, val[i], allocator)
		}
		strings.write_byte(sb, ']')
	case JSONObject:
		strings.write_byte(sb, '{')
		for i in 0..<json_object_len(val) {
			if i > 0 { strings.write_byte(sb, ',') }
			json_write_string(sb, val.keys[i])
			strings.write_byte(sb, ':')
			json_write(sb, val.values[i], allocator)
		}
		strings.write_byte(sb, '}')
	case:
		strings.write_string(sb, "null")
	}
}

json_write_string :: proc(sb: ^strings.Builder, s: string) {
	strings.write_byte(sb, '"')
	for r in s {
		switch r {
		case '"':
			strings.write_string(sb, "\\\"")
		case '\\':
			strings.write_string(sb, "\\\\")
		case '\n':
			strings.write_string(sb, "\\n")
		case '\r':
			strings.write_string(sb, "\\r")
		case '\t':
			strings.write_string(sb, "\\t")
		case '\b':
			strings.write_string(sb, "\\b")
		case '\f':
			strings.write_string(sb, "\\f")
		case:
			if r < 0x20 {
				strings.write_string(sb, fmt.tprintf("\\u%04x", u16(r)))
			} else {
				strings.write_rune(sb, r)
			}
		}
	}
	strings.write_byte(sb, '"')
}

// ── Parser ────────────────────────────────────────────────────────────────

// json_parse decodes a JSON byte slice into a value. On error it returns nil
// and a non-empty error message.
json_parse :: proc(data: []u8, allocator := context.allocator) -> (JSONValue, string) {
	p := Parser{data = data, allocator = allocator}
	skip_ws(&p)
	v, err := parse_value(&p)
	if err != "" { return nil, err }
	skip_ws(&p)
	if p.pos < len(p.data) {
		return nil, fmt.tprintf("trailing data at offset %d", p.pos)
	}
	return v, ""
}

Parser :: struct {
	data:      []u8,
	pos:       int,
	allocator: mem.Allocator,
}

skip_ws :: proc(p: ^Parser) {
	for p.pos < len(p.data) {
		c := p.data[p.pos]
		if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
			p.pos += 1
		} else {
			break
		}
	}
}

parse_value :: proc(p: ^Parser) -> (JSONValue, string) {
	skip_ws(p)
	if p.pos >= len(p.data) { return nil, "unexpected end of input" }
	c := p.data[p.pos]
	switch c {
	case '{':
		return parse_object(p)
	case '[':
		return parse_array(p)
	case '"':
		return parse_string_value(p)
	case 't', 'f':
		return parse_bool(p)
	case 'n':
		return parse_null(p)
	case:
		return parse_number(p)
	}
}

parse_object :: proc(p: ^Parser) -> (JSONValue, string) {
	p.pos += 1 // consume '{'
	o := json_object_make(p.allocator)
	skip_ws(p)
	if p.pos < len(p.data) && p.data[p.pos] == '}' {
		p.pos += 1
		return o, ""
	}
	for {
		skip_ws(p)
		key, err := parse_string(p)
		if err != "" {
			json_destroy(o, p.allocator)
			return nil, err
		}
		skip_ws(p)
		if p.pos >= len(p.data) || p.data[p.pos] != ':' {
			free_string(key, p.allocator)
			json_destroy(o, p.allocator)
			return nil, "expected ':' after object key"
		}
		p.pos += 1
		v, err2 := parse_value(p)
		if err2 != "" {
			free_string(key, p.allocator)
			json_destroy(o, p.allocator)
			return nil, err2
		}
		json_object_set(&o, key, v, p.allocator)
		free_string(key, p.allocator)
		skip_ws(p)
		if p.pos >= len(p.data) {
			json_destroy(o, p.allocator)
			return nil, "unterminated object"
		}
		switch p.data[p.pos] {
		case ',':
			p.pos += 1
		case '}':
			p.pos += 1
			return o, ""
		case:
			json_destroy(o, p.allocator)
			return nil, fmt.tprintf("expected ',' or '}' at offset %d", p.pos)
		}
	}
}

parse_array :: proc(p: ^Parser) -> (JSONValue, string) {
	p.pos += 1 // consume '['
	arr := make([dynamic]JSONValue, p.allocator)
	skip_ws(p)
	if p.pos < len(p.data) && p.data[p.pos] == ']' {
		p.pos += 1
		return JSONArray(arr), ""
	}
	for {
		v, err := parse_value(p)
		if err != "" {
			for item in arr { json_destroy(item, p.allocator) }
			free_dyn(arr)
			return nil, err
		}
		append(&arr, v)
		skip_ws(p)
		if p.pos >= len(p.data) {
			for item in arr { json_destroy(item, p.allocator) }
			free_dyn(arr)
			return nil, "unterminated array"
		}
		switch p.data[p.pos] {
		case ',':
			p.pos += 1
		case ']':
			p.pos += 1
			return JSONArray(arr), ""
		case:
			for item in arr { json_destroy(item, p.allocator) }
			free_dyn(arr)
			return nil, fmt.tprintf("expected ',' or ']' at offset %d", p.pos)
		}
	}
}

parse_string_value :: proc(p: ^Parser) -> (JSONValue, string) {
	s, err := parse_string(p)
	if err != "" { return nil, err }
	return JSONString(s), ""
}

parse_string :: proc(p: ^Parser) -> (string, string) {
	if p.pos >= len(p.data) || p.data[p.pos] != '"' {
		return "", "expected '\"' to start string"
	}
	p.pos += 1
	sb := strings.builder_make(p.allocator)
	for {
		if p.pos >= len(p.data) {
			free_dyn(sb.buf)
			return "", "unterminated string"
		}
		c := p.data[p.pos]
		if c == '"' {
			p.pos += 1
			view := strings.to_string(sb)
			out, _ := strings.clone(view, p.allocator)
			free_dyn(sb.buf)
			return out, ""
		}
		if c == '\\' {
			p.pos += 1
			if p.pos >= len(p.data) {
				free_dyn(sb.buf)
				return "", "unterminated escape"
			}
			e := p.data[p.pos]
			p.pos += 1
			switch e {
			case '"':
				strings.write_byte(&sb, '"')
			case '\\':
				strings.write_byte(&sb, '\\')
			case '/':
				strings.write_byte(&sb, '/')
			case 'n':
				strings.write_byte(&sb, '\n')
			case 'r':
				strings.write_byte(&sb, '\r')
			case 't':
				strings.write_byte(&sb, '\t')
			case 'b':
				strings.write_byte(&sb, '\b')
			case 'f':
				strings.write_byte(&sb, '\f')
			case 'u':
				if p.pos + 4 > len(p.data) {
					free_dyn(sb.buf)
					return "", "short \\u escape"
				}
				hex := string(p.data[p.pos:p.pos+4])
				code, ok := parse_hex4(hex)
				if !ok {
					free_dyn(sb.buf)
					return "", "bad \\u escape"
				}
				p.pos += 4
				strings.write_rune(&sb, code)
			case:
				free_dyn(sb.buf)
				return "", fmt.tprintf("bad escape '\\%c'", rune(e))
			}
		} else {
			// Collect the byte; multi-byte UTF-8 sequences are forwarded raw
			// so they round-trip intact when re-encoded.
			strings.write_byte(&sb, c)
			p.pos += 1
		}
	}
}

parse_hex4 :: proc(s: string) -> (rune, bool) {
	code := 0
	for r in s {
		code <<= 4
		switch {
		case r >= '0' && r <= '9':
			code += int(r - '0')
		case r >= 'a' && r <= 'f':
			code += int(r - 'a') + 10
		case r >= 'A' && r <= 'F':
			code += int(r - 'A') + 10
		case:
			return 0, false
		}
	}
	return rune(code), true
}

parse_bool :: proc(p: ^Parser) -> (JSONValue, string) {
	if match_literal(p, "true") { return JSONBool(true), "" }
	if match_literal(p, "false") { return JSONBool(false), "" }
	return nil, "invalid literal"
}

parse_null :: proc(p: ^Parser) -> (JSONValue, string) {
	if match_literal(p, "null") { return JSONNull{}, "" }
	return nil, "invalid literal"
}

match_literal :: proc(p: ^Parser, lit: string) -> bool {
	if p.pos + len(lit) > len(p.data) { return false }
	for i in 0..<len(lit) {
		if p.data[p.pos + i] != lit[i] { return false }
	}
	p.pos += len(lit)
	return true
}

parse_number :: proc(p: ^Parser) -> (JSONValue, string) {
	start := p.pos
	is_float := false
	if p.pos < len(p.data) && p.data[p.pos] == '-' { p.pos += 1 }
	for p.pos < len(p.data) {
		c := p.data[p.pos]
		switch c {
		case '0','1','2','3','4','5','6','7','8','9':
			p.pos += 1
		case '.', 'e', 'E', '+', '-':
			is_float = true
			p.pos += 1
		case:
			break
		}
	}
	num_str := string(p.data[start:p.pos])
	if is_float {
		f, ok := strconv_parse_f64(num_str)
		if !ok { return nil, fmt.tprintf("bad float '%s'", num_str) }
		return JSONFloat(f), ""
	}
	i, ok := strconv_parse_i64(num_str)
	if !ok {
		f, ok2 := strconv_parse_f64(num_str)
		if !ok2 { return nil, fmt.tprintf("bad number '%s'", num_str) }
		return JSONFloat(f), ""
	}
	return JSONInteger(i), ""
}

// strconv_parse_i64 parses a base-10 integer. Returns (value, ok).
strconv_parse_i64 :: proc(s: string) -> (i64, bool) {
	if s == "" { return 0, false }
	neg := false
	i := 0
	if s[0] == '-' { neg = true; i = 1 }
	if i >= len(s) { return 0, false }
	v: i64 = 0
	for i < len(s) {
		c := s[i]
		if c < '0' || c > '9' { return 0, false }
		v = v * 10 + i64(c - '0')
		i += 1
	}
	if neg { v = -v }
	return v, true
}

// strconv_parse_f64 parses a float. Returns (value, ok).
strconv_parse_f64 :: proc(s: string) -> (f64, bool) {
	if s == "" { return 0, false }
	neg := false
	i := 0
	if s[0] == '-' { neg = true; i = 1 }
	if i >= len(s) { return 0, false }
	v: f64 = 0
	has_int := false
	for i < len(s) && s[i] >= '0' && s[i] <= '9' {
		v = v * 10 + f64(s[i] - '0')
		i += 1
		has_int = true
	}
	if i < len(s) && s[i] == '.' {
		i += 1
		scale: f64 = 0.1
		for i < len(s) && s[i] >= '0' && s[i] <= '9' {
			v += f64(s[i] - '0') * scale
			scale *= 0.1
			i += 1
			has_int = true
		}
	}
	if i < len(s) && (s[i] == 'e' || s[i] == 'E') {
		i += 1
		exp_neg := false
		if i < len(s) && (s[i] == '+' || s[i] == '-') {
			exp_neg = s[i] == '-'
			i += 1
		}
		exp := 0
		for i < len(s) && s[i] >= '0' && s[i] <= '9' {
			exp = exp * 10 + int(s[i] - '0')
			i += 1
		}
		mul := math_pow10(exp)
		if exp_neg { v /= mul } else { v *= mul }
	}
	if i != len(s) { return 0, false }
	if !has_int { return 0, false }
	if neg { v = -v }
	return v, true
}

// math_pow10 returns 10^exp as an f64.
math_pow10 :: proc(exp: int) -> f64 {
	r: f64 = 1.0
	for _ in 0..<exp {
		r *= 10.0
	}
	return r
}
