// Port of src/dbus.vala: the NotificationDaemon object. The [DBus] attributes
// become a dispatch on the method name of each wnotify request line.
package main

import "core:fmt"
import "core:strconv"
import "core:sync"

import "wnotify"

NotificationDaemon :: struct {
	notification_id: u32, // Vala: public static uint notification_id = 1;
	lock:            sync.Mutex,
	server:          ^wnotify.Server,
}

daemon := NotificationDaemon {
	notification_id = 1,
}

// Called on the client's pipe thread (GDBus called Vala on the main loop),
// hence the lock around the id counter.
handle_request :: proc(c: ^wnotify.Conn, f: []string, user: rawptr) {
	switch f[0] {
	case "GetServerInformation":
		// name, vendor, version, spec_version
		wnotify.reply(c, wnotify.join("OK", "tiramisu", "Sweets", "2.0-odin", wnotify.SPEC_VERSION, allocator = context.temp_allocator))

	case "GetCapabilities":
		wnotify.reply(c, "OK\tbody\tactions\ticon-static")

	case "Notify":
		n, ok := wnotify.parse_notify(f, context.temp_allocator)
		if !ok {
			wnotify.reply_err(c, "malformed Notify")
			return
		}
		id: u32
		{
			sync.guard(&daemon.lock)
			// if (replaces_id == 0) return notification_id++; return replaces_id;
			if n.replaces_id == 0 {
				id = daemon.notification_id
				daemon.notification_id += 1
			} else {
				id = n.replaces_id
			}
			output(n, id)
		}
		wnotify.reply(c, fmt.tprintf("OK\t%d", id))

	case "CloseNotification":
		// Vala: "// close notification" (no-op). The spec requires the
		// NotificationClosed signal, which `notify-send -w` waits for.
		id: u64
		if len(f) > 1 do id, _ = strconv.parse_u64(f[1])
		wnotify.reply_ok(c)
		wnotify.emit_closed(daemon.server, u32(id), .Closed)

	case:
		wnotify.reply_err(c, "unknown method")
	}
}
