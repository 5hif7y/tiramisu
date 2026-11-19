// wnotify - org.freedesktop.Notifications over a Windows named pipe.
// Odin implementation of the protocol in LowLevel-Katas N4-notifications/wnotify/PROTOCOL.md
// (wire-compatible with the C wnotify.c: same pipe name, framing and escapes).
package wnotify

import "base:runtime"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import win "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention = "system")
foreign kernel32 {
	ProcessIdToSessionId :: proc(dwProcessId: win.DWORD, pSessionId: ^win.DWORD) -> win.BOOL ---
}

SPEC_VERSION :: "1.2"
MAX_LINE :: 64 * 1024 * 1024
PIPE_BUF :: 64 * 1024
PIPE_UNLIMITED_INSTANCES :: 255

Close_Reason :: enum u32 {
	Expired   = 1,
	Dismissed = 2,
	Closed    = 3, // CloseNotification
	Undefined = 4,
}

Hint :: struct {
	name, type, value: string, // type: D-Bus signature char or "image"
}

Notify :: struct {
	app_name:       string,
	replaces_id:    u32,
	app_icon:       string,
	summary:        string,
	body:           string,
	actions:        []string, // flat: key, label, key, label
	hints:          []Hint,
	expire_timeout: i32,
}

// ---- codec ---------------------------------------------------------------

escape :: proc(b: ^strings.Builder, s: string) {
	for i in 0 ..< len(s) {
		switch s[i] {
		case '\\': strings.write_string(b, `\\`)
		case '\t': strings.write_string(b, `\t`)
		case '\n': strings.write_string(b, `\n`)
		case '\r': strings.write_string(b, `\r`)
		case:      strings.write_byte(b, s[i])
		}
	}
}

unescape :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(0, len(s), allocator)
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		if c == '\\' && i + 1 < len(s) {
			i += 1
			switch s[i] {
			case 't': c = '\t'
			case 'n': c = '\n'
			case 'r': c = '\r'
			case:     c = s[i]
			}
		}
		strings.write_byte(&b, c)
	}
	return strings.to_string(b)
}

// Split a line on TAB and unescape every field (fields are newly allocated).
split :: proc(line: string, allocator := context.allocator) -> []string {
	raw := strings.split(line, "\t", context.temp_allocator)
	out := make([]string, len(raw), allocator)
	for f, i in raw {
		out[i] = unescape(f, allocator)
	}
	return out
}

// Build a protocol line from already-unescaped fields.
join :: proc(fields: ..string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for f, i in fields {
		if i > 0 do strings.write_byte(&b, '\t')
		escape(&b, f)
	}
	return strings.to_string(b)
}

parse_notify :: proc(f: []string, allocator := context.allocator) -> (n: Notify, ok: bool) {
	if len(f) < 9 || f[0] != "Notify" do return {}, false
	i := 1
	n.app_name = f[i]; i += 1
	rid, rid_ok := strconv.parse_u64(f[i]); i += 1
	if !rid_ok do return {}, false
	n.replaces_id = u32(rid)
	n.app_icon = f[i]; i += 1
	n.summary = f[i]; i += 1
	n.body = f[i]; i += 1

	na, na_ok := strconv.parse_int(f[i]); i += 1
	if !na_ok || na < 0 || na % 2 != 0 || i + na >= len(f) do return {}, false
	n.actions = f[i:i + na]
	i += na

	nh, nh_ok := strconv.parse_int(f[i]); i += 1
	if !nh_ok || nh < 0 || i + nh * 3 + 1 != len(f) do return {}, false
	hints := make([dynamic]Hint, 0, nh, allocator)
	for _ in 0 ..< nh {
		h := Hint{f[i], f[i + 1], f[i + 2]}
		i += 3
		// a{sv}: last value for a key wins
		replaced := false
		for &old in hints {
			if old.name == h.name {
				old = h
				replaced = true
			}
		}
		if !replaced do append(&hints, h)
	}
	n.hints = hints[:]

	t, t_ok := strconv.parse_i64(f[i])
	if !t_ok do return {}, false
	n.expire_timeout = i32(t)
	return n, true
}

// WNOTIFY_PIPE, else \\.\pipe\org.freedesktop.Notifications.<SessionId>
pipe_name :: proc(allocator := context.allocator) -> string {
	buf: [512]u16
	n := win.GetEnvironmentVariableW(win.L("WNOTIFY_PIPE"), &buf[0], len(buf))
	if n > 0 && n < len(buf) {
		s, _ := win.utf16_to_utf8(buf[:n], allocator)
		return s
	}
	sid: win.DWORD
	ProcessIdToSessionId(win.GetCurrentProcessId(), &sid)
	return fmt.aprintf(`\\.\pipe\org.freedesktop.Notifications.%d`, sid, allocator = allocator)
}

// ---- server --------------------------------------------------------------
//
// One thread per client. The handle MUST be overlapped: a connection thread
// sits in ReadFile while other threads write signals (emit) to the same
// handle. On a synchronous handle Windows serializes I/O per handle, so that
// WriteFile would wait for the ReadFile to finish - i.e. for the client to
// speak first. Subscribers never speak: deadlock. (The first version of this
// port did exactly that; `notify-send -w` hung forever.)

Handler :: #type proc(c: ^Conn, fields: []string, user: rawptr)

Server :: struct {
	name:    string,
	handler: Handler,
	user:    rawptr,
	lock:    sync.Mutex,
	subs:    [dynamic]^Conn,
	first:   win.HANDLE,
	ctx:     runtime.Context,
}

Conn :: struct {
	srv:        ^Server,
	pipe:       win.HANDLE,
	rd_ev:      win.HANDLE,
	wr_ev:      win.HANDLE,
	wlock:      sync.Mutex,
	subscribed: bool,
}

// Overlapped read/write that blocks this thread only.
@(private)
ov_io :: proc(pipe, ev: win.HANDLE, write: bool, buf: rawptr, n: int) -> (done: int, ok: bool) {
	ov := win.OVERLAPPED{hEvent = ev}
	got: win.DWORD
	r := write ? win.WriteFile(pipe, buf, win.DWORD(n), nil, &ov) : win.ReadFile(pipe, buf, win.DWORD(n), nil, &ov)
	if !r && win.GetLastError() != win.ERROR_IO_PENDING do return 0, false
	if !win.GetOverlappedResult(pipe, &ov, &got, true) do return 0, false
	return int(got), true
}

@(private)
make_instance :: proc(name: string, first: bool) -> win.HANDLE {
	open_mode := win.PIPE_ACCESS_DUPLEX | win.FILE_FLAG_OVERLAPPED
	if first do open_mode |= win.FILE_FLAG_FIRST_PIPE_INSTANCE
	return win.CreateNamedPipeW(
		win.utf8_to_wstring(name),
		open_mode,
		win.PIPE_TYPE_BYTE | win.PIPE_READMODE_BYTE | win.PIPE_WAIT | win.PIPE_REJECT_REMOTE_CLIENTS,
		PIPE_UNLIMITED_INSTANCES,
		PIPE_BUF,
		PIPE_BUF,
		0,
		nil,
	)
}

// Claims the pipe name (like g_bus_own_name with DO_NOT_QUEUE) and starts
// accepting clients. Returns an error message if another daemon owns it.
server_start :: proc(handler: Handler, user: rawptr = nil) -> (s: ^Server, err: string) {
	s = new(Server)
	s.name = pipe_name()
	s.handler = handler
	s.user = user
	s.ctx = context
	s.first = make_instance(s.name, true)
	if s.first == win.INVALID_HANDLE_VALUE {
		e := win.GetLastError()
		if e == win.ERROR_ACCESS_DENIED {
			return nil, fmt.aprintf("another notification daemon owns %s", s.name)
		}
		return nil, fmt.aprintf("CreateNamedPipe(%s) failed: %d", s.name, e)
	}
	thread.create_and_start_with_poly_data(s, accept_main, s.ctx, self_cleanup = true)
	return s, ""
}

@(private)
accept_main :: proc(s: ^Server) {
	pipe := s.first
	ev := win.CreateEventW(nil, true, false, nil)
	for {
		ov := win.OVERLAPPED{hEvent = ev}
		ok := win.ConnectNamedPipe(pipe, &ov)
		e := win.GetLastError()
		if !ok && e == win.ERROR_IO_PENDING {
			got: win.DWORD
			ok = win.GetOverlappedResult(pipe, &ov, &got, true)
		} else if !ok && e == win.ERROR_PIPE_CONNECTED {
			ok = true
		}
		if !ok {
			win.CloseHandle(pipe)
		} else {
			c := new(Conn)
			c.srv = s
			c.pipe = pipe
			c.rd_ev = win.CreateEventW(nil, true, false, nil)
			c.wr_ev = win.CreateEventW(nil, true, false, nil)
			thread.create_and_start_with_poly_data(c, conn_main, s.ctx, self_cleanup = true)
		}
		pipe = make_instance(s.name, false)
		if pipe == win.INVALID_HANDLE_VALUE do return
	}
}

@(private)
conn_main :: proc(c: ^Conn) {
	buf := make([dynamic]u8, 0, PIPE_BUF)
	defer delete(buf)
	chunk: [PIPE_BUF]u8
	loop: for {
		// complete lines already buffered?
		for {
			nl := -1
			for b, i in buf {
				if b == '\n' {nl = i; break}
			}
			if nl < 0 do break
			line := string(buf[:nl])
			line = strings.trim_suffix(line, "\r")
			fields := split(line, context.temp_allocator)
			if fields[0] == "Subscribe" {
				sync.guard(&c.srv.lock)
				c.subscribed = true
				append(&c.srv.subs, c)
				reply(c, "OK")
			} else {
				c.srv.handler(c, fields, c.srv.user)
			}
			remove_range(&buf, 0, nl + 1)
			free_all(context.temp_allocator)
		}
		if len(buf) > MAX_LINE do break loop
		got, ok := ov_io(c.pipe, c.rd_ev, false, &chunk[0], len(chunk))
		if !ok || got == 0 do break loop
		append(&buf, ..chunk[:got])
	}
	{
		sync.guard(&c.srv.lock)
		for sub, i in c.srv.subs {
			if sub == c {unordered_remove(&c.srv.subs, i); break}
		}
	}
	{
		sync.guard(&c.wlock) // an emit() may be writing right now
		win.DisconnectNamedPipe(c.pipe)
		win.CloseHandle(c.pipe)
	}
	win.CloseHandle(c.rd_ev)
	win.CloseHandle(c.wr_ev)
	free(c)
}

reply :: proc(c: ^Conn, line: string) {
	sync.guard(&c.wlock)
	data := strings.concatenate({line, "\n"}, context.temp_allocator)
	off := 0
	for off < len(data) {
		w, ok := ov_io(c.pipe, c.wr_ev, true, raw_data(data[off:]), len(data) - off)
		if !ok do return
		off += w
	}
}

reply_ok :: proc(c: ^Conn) {reply(c, "OK")}

reply_err :: proc(c: ^Conn, msg: string) {
	reply(c, join("ERR", msg, allocator = context.temp_allocator))
}

// Broadcast a signal to every subscriber.
emit :: proc(s: ^Server, line: string) {
	sync.guard(&s.lock)
	for c in s.subs do reply(c, line)
}

emit_closed :: proc(s: ^Server, id: u32, reason: Close_Reason) {
	emit(s, fmt.tprintf("NotificationClosed\t%d\t%d", id, u32(reason)))
}

emit_action :: proc(s: ^Server, id: u32, action_key: string) {
	emit(s, join("ActionInvoked", fmt.tprint(id), action_key, allocator = context.temp_allocator))
}
