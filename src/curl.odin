// libcurl bindings (C FFI) for the mongreldb Odin client.
//
// Odin's `core:net` is a low-level sockets layer with no built-in HTTP client.
// Rather than implement an HTTP/1.1 client on raw sockets, the mongreldb Odin
// client uses libcurl via C FFI - libcurl is universally available on Linux
// (the CI platform). The functions declared here wrap exactly the curl calls
// the client needs: a single request with optional JSON body, auth headers,
// and a response body buffer.
//
// `curl_perform` runs one synchronous request and returns the response body
// (heap-allocated in `allocator`), the HTTP status code, and an ok flag. The
// response is read into a pre-allocated buffer so the libcurl write callback
// never needs to grow memory (Odin's `context.allocator` is unavailable inside
// a C-calling-convention callback).

package mongreldb

import "core:c"
import "core:fmt"
import "core:mem"
import "core:strings"

// Method is the HTTP verb the client uses.
Method :: enum {
	GET,
	POST,
	DELETE,
}

// CURL is libcurl's opaque easy-handle type (forward declared as an empty
// struct so Odin can take a pointer to it).
CURL :: struct {}

// CURL_SList is libcurl's linked-list type for HTTP headers.
CURL_SList :: distinct rawptr

// CURLE_OK from libcurl.
CURLE_OK :: 0

// CURLoption values used by the client (from curl/curl.h).
CURLOPT_URL :: i32(10002)
CURLOPT_WRITEFUNCTION :: i32(10011)
CURLOPT_WRITEDATA :: i32(10001)
CURLOPT_POSTFIELDS :: i32(10015)
CURLOPT_HTTPHEADER :: i32(10023)
CURLOPT_CUSTOMREQUEST :: i32(10036)
CURLOPT_FOLLOWLOCATION :: i32(10052)
CURLOPT_HEADER :: i32(10058)

// CURLINFO response code info.
CURLINFO_RESPONSE_CODE :: u32(0x200002)

// recv_buffer_size is the working buffer pre-allocated per request for the
// response body. It is large enough for all practical daemon responses (the
// full 256 MB cap is enforced separately in raw_request). Allocated and freed
// once per request; no growth happens inside the C callback.
recv_buffer_size :: u64(64 * 1024 * 1024)

// foreign declarations against libcurl. `foreign import lib "system:curl"`
// links the shared libcurl; the `foreign lib { ... }` block declares the
// exact symbols the client calls. `@(link_name=...)` maps the Odin name to
// the C symbol.
foreign import lib "system:curl"

foreign lib {
	@(link_name="curl_global_init")
	global_init :: proc(flags: i64) -> i32 ---

	@(link_name="curl_easy_init")
	easy_init :: proc() -> ^CURL ---

	@(link_name="curl_easy_cleanup")
	easy_cleanup :: proc(handle: ^CURL) ---

	@(link_name="curl_easy_perform")
	easy_perform :: proc(handle: ^CURL) -> i32 ---

	@(link_name="curl_easy_getinfo")
	easy_getinfo :: proc(handle: ^CURL, info: u32, #c_vararg args: ..any) -> i32 ---

	@(link_name="curl_easy_setopt")
	easy_setopt :: proc(handle: ^CURL, opt: i32, #c_vararg args: ..any) -> i32 ---

	@(link_name="curl_slist_append")
	slist_append :: proc(list: CURL_SList, str: cstring) -> CURL_SList ---

	@(link_name="curl_slist_free_all")
	slist_free_all :: proc(list: CURL_SList) ---
}

// Recv_Buffer is the fixed-capacity sink the C write callback appends into.
// It carries no allocator - libcurl's callback must have C calling convention,
// which makes Odin's `context` (and thus `context.allocator`) unavailable, so
// the buffer is sized up front by `curl_perform` and bounds-checked here.
Recv_Buffer :: struct {
	data: [^]u8,
	len:  u64,
	cap:  u64,
}

// curl_write_cb is the write callback installed via CURLOPT_WRITEFUNCTION. It
// copies received bytes into the `Recv_Buffer` passed through WRITEDATA,
// stopping at the buffer's capacity.
curl_write_cb :: proc "c" (ptr: rawptr, size: c.size_t, nmemb: c.size_t, data: rawptr) -> c.size_t {
	if size == 0 || nmemb == 0 { return 0 }
	total := int(size) * int(nmemb)
	rb := (^Recv_Buffer)(data)
	if rb.len + u64(total) > rb.cap {
		// Refuse to overflow - return a short count so curl aborts the
		// transfer (CURLE_WRITE_ERROR), which curl_perform reports as !ok.
		fit := int(rb.cap - rb.len)
		if fit <= 0 { return 0 }
		src := ([^]u8)(ptr)[:fit]
		dst := ([^]u8)(rb.data)[rb.len:]
		for i in 0..<fit { dst[i] = src[i] }
		rb.len += u64(fit)
		return c.size_t(fit)
	}
	src := ([^]u8)(ptr)[:total]
	dst := ([^]u8)(rb.data)[rb.len:]
	for i in 0..<total { dst[i] = src[i] }
	rb.len += u64(total)
	return c.size_t(total)
}

curl_inited: bool = false

// curl_init_once initializes curl's global state exactly once per process.
// Idempotent.
curl_init_once :: proc() {
	if curl_inited { return }
	global_init(0)
	curl_inited = true
}

// to_cstring returns a NUL-terminated copy of `s` (owned by the caller, free
// with `delete`). libcurl needs cstrings; Odin strings are not NUL-terminated.
to_cstring :: proc(s: string, allocator := context.allocator) -> cstring {
	cs, _ := strings.clone_to_cstring(s, allocator)
	return cs
}

// curl_perform runs one HTTP request. Returns:
//   - body: heap-allocated response bytes (owned by the caller; free with
//     `delete(body, allocator)`).
//   - status: the HTTP response code.
//   - ok: false if curl failed (transport error); true otherwise.
curl_perform :: proc(
	url: string,
	method: Method,
	has_body: bool,
	body: string,
	token: string,
	username: string,
	password: string,
	allocator: mem.Allocator,
) -> (body_out: []u8, status: int, ok: bool) {
	curl_init_once()

	handle := easy_init()
	if handle == nil { return nil, 0, false }
	defer easy_cleanup(handle)

	// URL.
	url_c := to_cstring(url, allocator)
	defer free_cstring(url_c, allocator)
	_ = easy_setopt(handle, CURLOPT_URL, url_c)

	// HTTP method. libcurl defaults to GET; set POSTFIELDS for POST, and use
	// CUSTOMREQUEST for DELETE.
	if method == .DELETE {
		del_c := to_cstring("DELETE", allocator)
		defer free_cstring(del_c, allocator)
		_ = easy_setopt(handle, CURLOPT_CUSTOMREQUEST, del_c)
	}

	if has_body && method == .POST {
		body_c := to_cstring(body, allocator)
		defer free_cstring(body_c, allocator)
		_ = easy_setopt(handle, CURLOPT_POSTFIELDS, body_c)
	}

	// Headers: Accept + Content-Type (when body), plus auth. curl_slist_append
	// copies its string argument, so the cstring only needs to live for the
	// duration of the append.
	headers: CURL_SList = nil
	defer if headers != nil { slist_free_all(headers) }

	accept_c := to_cstring("Accept: application/json", allocator)
	defer free_cstring(accept_c, allocator)
	headers = slist_append(headers, accept_c)

	if has_body {
		ct_c := to_cstring("Content-Type: application/json", allocator)
		defer free_cstring(ct_c, allocator)
		headers = slist_append(headers, ct_c)
	}

	// Bearer token takes precedence over basic auth.
	if token != "" {
		auth_hdr := fmt.tprintf("Authorization: Bearer %s", token)
		auth_c := to_cstring(auth_hdr, allocator)
		defer free_string(auth_hdr, allocator)
		defer free_cstring(auth_c, allocator)
		headers = slist_append(headers, auth_c)
	} else if username != "" {
		creds := fmt.tprintf("%s:%s", username, password)
		defer free_string(creds, allocator)
		creds_b64 := base64_encode(creds, allocator)
		defer free_string(creds_b64, allocator)
		auth_hdr := fmt.tprintf("Authorization: Basic %s", creds_b64)
		defer free_string(auth_hdr, allocator)
		auth_c := to_cstring(auth_hdr, allocator)
		defer free_cstring(auth_c, allocator)
		headers = slist_append(headers, auth_c)
	}
	_ = easy_setopt(handle, CURLOPT_HTTPHEADER, rawptr(headers))

	// Response body buffer, pre-allocated to recv_buffer_size.
	recv_buf := make([]u8, recv_buffer_size, allocator)
	defer free_slice(recv_buf, allocator)
	rb := Recv_Buffer{data = raw_data(recv_buf), len = 0, cap = recv_buffer_size}
	_ = easy_setopt(handle, CURLOPT_WRITEFUNCTION, curl_write_cb)
	_ = easy_setopt(handle, CURLOPT_WRITEDATA, rawptr(&rb))

	// Don't fold response headers into the body; don't follow redirects (the
	// client maps 3xx to a transport error category).
	_ = easy_setopt(handle, CURLOPT_HEADER, 0)
	_ = easy_setopt(handle, CURLOPT_FOLLOWLOCATION, 0)

	rc := easy_perform(handle)
	if rc != CURLE_OK { return nil, 0, false }

	code: i64 = 0
	_ = easy_getinfo(handle, CURLINFO_RESPONSE_CODE, &code)

	// Copy out exactly the bytes received into a right-sized slice.
	out := make([]u8, rb.len, allocator)
	copy(out, recv_buf[:rb.len])
	return out, int(code), true
}

// base64_encode base64-encodes a string for HTTP Basic auth credentials.
// The returned string is owned by the caller (free with `delete`).
base64_encode :: proc(input: string, allocator := context.allocator) -> string {
	table := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	src := transmute([]u8)input
	out := make([dynamic]u8, 0, ((len(src) + 2) / 3) * 4, allocator)
	defer free_dyn(out)

	i := 0
	for i + 2 < len(src) {
		n := u32(src[i]) << 16 | u32(src[i+1]) << 8 | u32(src[i+2])
		append(&out, table[(n >> 18) & 0x3f])
		append(&out, table[(n >> 12) & 0x3f])
		append(&out, table[(n >> 6) & 0x3f])
		append(&out, table[n & 0x3f])
		i += 3
	}
	rem := len(src) - i
	if rem == 1 {
		n := u32(src[i]) << 16
		append(&out, table[(n >> 18) & 0x3f])
		append(&out, table[(n >> 12) & 0x3f])
		append(&out, '=')
		append(&out, '=')
	} else if rem == 2 {
		n := u32(src[i]) << 16 | u32(src[i+1]) << 8
		append(&out, table[(n >> 18) & 0x3f])
		append(&out, table[(n >> 12) & 0x3f])
		append(&out, table[(n >> 6) & 0x3f])
		append(&out, '=')
	}

	view := string(out[:])
	out_str, _ := strings.clone(view, allocator)
	return out_str
}
