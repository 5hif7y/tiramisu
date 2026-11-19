# tiramisu — Odin port (from the Vala rewrite), native Windows

Branch `port/odin`, forked from `master` (`5dddd83`, Vala). The Vala sources in
`src/` are kept untouched for reference; the port lives in `odin/`, one file
per Vala file:

| Vala | Odin | |
|---|---|---|
| `src/tiramisu.vala` | `odin/tiramisu.odin` | `GLib.Application`, `OptionEntry` → `parse_args`, `hold()` → wait on an event |
| `src/dbus.vala` | `odin/dbus.odin` | `[DBus]` class → dispatch on the request method name |
| `src/notification.vala` | `odin/notification.odin` | `HashTable<string,Variant>` → `[]wnotify.Hint` |
| GDBus | `odin/wnotify/` | named-pipe transport, wire-compatible with the C `wnotify` |

```bat
odin\build.bat            :: -> tiramisu.exe
tiramisu -j
notify-send -a app "summary" "body"     :: notify-send from LowLevel-Katas N4-notifications
```

## Behaviour vs Vala

Kept: options `-o/--format`, `-j/--json`, `-s/--sanitize`; ids start at 1 and
`replaces_id` is honoured; CSV hints with `'quoted'` strings; actions in the
plain format joined with `,` (`default,Open`); capabilities and server info.

Brought back from the C history: `-d/--delimiter` (1.x), image-data length
validation (2.x C), JSON hints with real types and actions as an object (1.x).

Fixed: `#id` prints the assigned id (Vala printed `replaces_id`, 0 for new
notifications); backslash and every control char escaped (valid JSON); the
template is interpolated in one pass (a body containing `#summary` is not
expanded); no double escaping of string hints under `-s`;
`CloseNotification` emits `NotificationClosed(id, 3)`.

## Lesson learned

The first Odin server used synchronous pipe handles. A thread blocked in
`ReadFile` on a handle makes every `WriteFile` on the *same* handle wait,
so pushing a signal to a subscriber (who never writes) deadlocked. Pipes that
are read and written from different threads must be `FILE_FLAG_OVERLAPPED`.
