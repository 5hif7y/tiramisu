# tiramisu (C) for Windows — MSVC, no GLib, no D-Bus

Branch `port/c-msvc`, forked from `76932bb` (2021-10-09), the last commit
before the Vala rewrite (`f161a91 Remove C source files`).

```bat
build.bat                 :: -> tiramisu.exe  (or: cmake -S . -B build)
tiramisu.exe              :: one field per line
tiramisu.exe -j           :: one JSON object per line
tiramisu.exe -o "#source: #summary" -s
```

Clients: any program speaking **wnotify** (`notify-send.exe` from
LowLevel-Katas `N4-notifications/wnotify`), see `src/wnotify.h`.

## What replaced what

| Linux | Windows |
|---|---|
| D-Bus session bus, `g_bus_own_name` | named pipe `\.\pipe\org.freedesktop.Notifications.<SessionId>` (`WNOTIFY_PIPE` overrides), first-instance flag = name ownership |
| `GDBusInterfaceVTable` `event_handler` | `wn_request_fn` (`src/events.c`), one thread per client, id/stdout under a critical section |
| `GVariant` `(susssasa{sv}i)` | `wn_notify` parsed from a tab-separated line; hints keep their D-Bus type char |
| `GMainLoop` + `g_unix_signal_add` | manual-reset event + `SetConsoleCtrlHandler` |
| `getopt` | hand parser (MSVC CRT has none), long options from the Vala version |
| `printf` text mode | `_O_BINARY` stdout, LF only, UTF-8 |

## Features merged from every generation

* 1.x C (2020): typed hints, JSON objects for hints/actions, `-d` delimiter.
* 2.x C (2021): `-o` format, `-s`, `-j`, CSV hints, image-data length check.
* 2.x Vala: long options, `replaces_id`, `\r` escaping, quoted string hints, icon in JSON.
* Fixed: valid JSON (the 2.x C template used `'`), backslash and control chars
  escaped, `#id` prints the id actually assigned (Vala printed `replaces_id`, 0
  for new notifications), interpolation is single-pass (a body containing
  `#summary` is no longer expanded), `CloseNotification` emits
  `NotificationClosed(id, 3)`.
* Removed: `src/output.c`/`output.h`, dead code in 76932bb (not in the
  Makefile); its features live in `notification.c`.
