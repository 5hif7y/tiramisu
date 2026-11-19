// Port of src/notification.vala.
package main

import "core:encoding/base64"
import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import "core:sync"
import win "core:sys/windows"

import "wnotify"

// Vala: subj.replace("\"","\\\"").replace("\r","\\r").replace("\n","\\n")
//       // ideally all control sequences \u0000 to \u001f
// Done: backslash first (Vala forgot it -> invalid JSON), all control chars.
sanitize :: proc(subj: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	for i in 0 ..< len(subj) {
		c := subj[i]
		switch c {
		case '"':  strings.write_string(&b, `\"`)
		case '\\': strings.write_string(&b, `\\`)
		case '\n': strings.write_string(&b, `\n`)
		case '\r': strings.write_string(&b, `\r`)
		case '\t': strings.write_string(&b, `\t`)
		case:
			if c < 0x20 {
				fmt.sbprintf(&b, `\u%04x`, c)
			} else {
				strings.write_byte(&b, c)
			}
		}
	}
	return strings.to_string(b)
}

// Vala image_get_base64_representation(): the hint already travels as
// "w:h:stride:alpha:bps:channels:base64" over wnotify; what is left from the
// C version is the length check Vala dropped.
image_is_valid :: proc(value: string) -> bool {
	parts := strings.split_n(value, ":", 7, context.temp_allocator)
	if len(parts) != 7 do return false
	nums: [6]int
	for i in 0 ..< 6 {
		v, ok := strconv.parse_int(parts[i])
		if !ok do return false
		nums[i] = v
	}
	width, height, row_stride, bits_per_sample, channels := nums[0], nums[1], nums[2], nums[4], nums[5]
	if width <= 0 || height <= 0 || row_stride <= 0 || bits_per_sample <= 0 || channels <= 0 do return false
	pixels, err := base64.decode(parts[6], allocator = context.temp_allocator)
	if err != nil do return false
	pixel_stride := (channels * bits_per_sample + 7) / 8
	expected_length := (height - 1) * row_stride + width * pixel_stride
	return expected_length == len(pixels)
}

@(private = "file")
is_number :: proc(s: string) -> bool {
	v, ok := strconv.parse_f64(s)
	return ok && !math.is_nan(v) && !math.is_inf(v)
}

// Only if Tiramisu.json is true. Implies Tiramisu.sanitize.
create_hint_json_string :: proc(hints: []wnotify.Hint) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '{')
	separator := ""
	for h in hints {
		quoted: bool
		switch h.type {
		case "image":
			if !image_is_valid(h.value) do continue
			quoted = true
		case "b":
			quoted = h.value != "true" && h.value != "false"
		case "y", "n", "q", "i", "u", "x", "t", "d":
			quoted = !is_number(h.value) // Vala quoted every non-string: "\"5\""
		case:
			quoted = true
		}
		q := quoted ? `"` : ""
		fmt.sbprintf(&b, `%s"%s": %s%s%s`, separator, sanitize(h.name), q, sanitize(h.value), q)
		separator = ", "
	}
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

create_hint_csv_string :: proc(hints: []wnotify.Hint) -> string {
	b := strings.builder_make(context.temp_allocator)
	separator := ""
	for h in hints {
		value: string
		switch h.type {
		case "s":
			value = fmt.tprintf("'%s'", h.value)
		case "image":
			if !image_is_valid(h.value) do continue
			value = h.value
		case:
			value = h.value
		}
		key := h.name
		if Tiramisu.sanitize {
			key = sanitize(key)
			value = sanitize(value)
		}
		fmt.sbprintf(&b, "%s%s=%s", separator, key, value)
		separator = ","
	}
	return strings.to_string(b)
}

// Vala: string.joinv(",", actions) -> "default,Open". Kept for the plain
// format. In JSON, actions become an object {"key": "label"} (1.x C).
create_action_csv_string :: proc(actions: []string) -> string {
	joined := strings.join(actions, ",", context.temp_allocator)
	return Tiramisu.sanitize ? sanitize(joined) : joined
}

create_action_json_string :: proc(actions: []string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '{')
	for i := 0; i + 1 < len(actions); i += 2 {
		fmt.sbprintf(&b, `%s"%s": "%s"`, i > 0 ? ", " : "", sanitize(actions[i]), sanitize(actions[i + 1]))
	}
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

@(private = "file")
stdout_lock: sync.Mutex

// Vala Notification.output(). Interpolation is single-pass: a body that
// contains "#summary" is printed literally (Vala's chained .replace() would
// expand it).
output :: proc(n: wnotify.Notify, id: u32) {
	app_name, app_icon, summary, body := n.app_name, n.app_icon, n.summary, n.body
	fmt_str := Tiramisu.format
	hint_string, action_string: string

	if Tiramisu.json {
		fmt_str = Tiramisu.json_format
		hint_string = create_hint_json_string(n.hints)
		action_string = create_action_json_string(n.actions)
	} else {
		hint_string = create_hint_csv_string(n.hints)
		action_string = create_action_csv_string(n.actions)
	}

	if Tiramisu.sanitize {
		app_name = sanitize(app_name)
		app_icon = sanitize(app_icon)
		summary = sanitize(summary)
		body = sanitize(body)
	}

	Token :: struct {
		key, value: string,
	}
	table := [?]Token {
		{"#source", app_name},
		{"#id", fmt.tprint(id)}, // Vala printed replaces_id (0 for new ones)
		{"#icon", app_icon},
		{"#summary", summary},
		{"#body", body},
		{"#actions", action_string},
		{"#hints", hint_string},
		{"#timeout", fmt.tprint(n.expire_timeout)},
	}

	b := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(fmt_str); {
		matched := false
		if fmt_str[i] == '#' {
			for t in table {
				if strings.has_prefix(fmt_str[i:], t.key) {
					strings.write_string(&b, t.value)
					i += len(t.key)
					matched = true
					break
				}
			}
		}
		if !matched {
			strings.write_byte(&b, fmt_str[i])
			i += 1
		}
	}
	strings.write_byte(&b, '\n')

	// stdout.printf(fmt + "\n"); stdout.flush();  -- raw bytes, LF only.
	sync.guard(&stdout_lock)
	data := strings.to_string(b)
	out := win.GetStdHandle(win.STD_OUTPUT_HANDLE)
	for off := 0; off < len(data); {
		w: win.DWORD
		if !win.WriteFile(out, raw_data(data[off:]), win.DWORD(len(data) - off), &w, nil) do break
		off += int(w)
	}
}
