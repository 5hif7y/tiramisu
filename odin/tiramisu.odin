// Port of src/tiramisu.vala to Odin, for native Windows.
//
// Vala/GLib -> Odin/Win32:
//   GLib.Application + hold()            -> wait on an event until Ctrl+C / close
//   OptionEntry[] + add_main_option_entries -> parse_args (same short/long flags)
//   Bus.own_name(SESSION, ..., DO_NOT_QUEUE) -> wnotify.server_start (named pipe,
//                                            FILE_FLAG_FIRST_PIPE_INSTANCE)
//   connection.register_object(...)      -> handle_request (dbus.odin)
package main

import "core:fmt"
import "core:os"
import "core:strings"
import win "core:sys/windows"

import "wnotify"

Tiramisu_Options :: struct { // Vala: static fields of class Tiramisu
	format:      string,
	json_format: string,
	sanitize:    bool,
	json:        bool,
}

Tiramisu := Tiramisu_Options {
	format      = "#source\n#icon\n#id\n#summary\n#body\n#actions\n#hints\n#timeout",
	// actions/hints are JSON objects (Vala emitted "actions" as a string)
	json_format = `{"source": "#source", "id": #id, "summary": "#summary", "body": "#body", ` +
	`"icon": "#icon", "actions": #actions, "hints": #hints, "timeout": #timeout}`,
}

USAGE :: `Usage:
  tiramisu [OPTION...]

Help Options:
  -h, --help                  Show help options

Application Options:
  -o, --format=FORMAT         Output format specifier
                              (#source #icon #id #summary #body #actions #hints #timeout)
  -j, --json                  Output using JSON (implies --sanitize)
  -s, --sanitize              Sanitize output; escapes quotes
  -d, --delimiter=DELIM       Field separator of the default format (C 1.x -d)
`

parse_args :: proc(args: []string) -> (ok: bool) {
	delimiter: Maybe(string)
	format_set := false
	value :: proc(args: []string, i: ^int, inline: string, name: string) -> (string, bool) {
		if inline != "" do return inline, true
		if i^ + 1 < len(args) {
			i^ += 1
			return args[i^], true
		}
		fmt.eprintf("tiramisu: option %s requires a value\n", name)
		return "", false
	}
	for i := 1; i < len(args); i += 1 {
		a := args[i]
		if strings.has_prefix(a, "--") {
			name, _, inline := strings.partition(a[2:], "=")
			switch name {
			case "help":
				fmt.print(USAGE)
				os.exit(0)
			case "json":
				Tiramisu.json = true
			case "sanitize":
				Tiramisu.sanitize = true
			case "format":
				Tiramisu.format = value(args, &i, inline, a) or_return
				format_set = true
			case "delimiter":
				delimiter = value(args, &i, inline, a) or_return
			case:
				fmt.eprintf("tiramisu: unknown option %s\n", a)
				return false
			}
		} else if len(a) > 1 && a[0] == '-' {
			flags: for k := 1; k < len(a); k += 1 {
				switch a[k] {
				case 'h':
					fmt.print(USAGE)
					os.exit(0)
				case 'j':
					Tiramisu.json = true
				case 's':
					Tiramisu.sanitize = true
				case 'o':
					Tiramisu.format = value(args, &i, a[k + 1:], "-o") or_return
					format_set = true
					break flags
				case 'd':
					delimiter = value(args, &i, a[k + 1:], "-d") or_return
					break flags
				case:
					fmt.eprintf("tiramisu: unknown option -%c\n", a[k])
					return false
				}
			}
		} else {
			fmt.eprintf("tiramisu: unexpected argument %s\n", a)
			return false
		}
	}
	if d, has := delimiter.?; has && !format_set {
		Tiramisu.format, _ = strings.replace_all(Tiramisu.format, "\n", d)
	}
	return true
}

@(private = "file")
quit_event: win.HANDLE

// SIGINT/SIGTERM equivalent: Ctrl+C, Ctrl+Break, console close, logoff.
@(private = "file")
console_handler :: proc "system" (ctrl: win.DWORD) -> win.BOOL {
	win.SetEvent(quit_event)
	return true
}

main :: proc() {
	if !parse_args(os.args) {
		fmt.eprint(USAGE)
		os.exit(1)
	}
	// activate(): if (json) sanitize = true;
	if Tiramisu.json do Tiramisu.sanitize = true

	win.SetConsoleOutputCP(.UTF8)
	quit_event = win.CreateEventW(nil, true, false, nil)
	win.SetConsoleCtrlHandler(console_handler, true)

	server, err := wnotify.server_start(handle_request)
	if server == nil {
		// error("Unable to acquired DBus name.");
		fmt.eprintln("Unable to acquire the notifications pipe:", err)
		os.exit(1)
	}
	daemon.server = server

	// this.hold(): keep running until asked to quit
	win.WaitForSingleObject(quit_event, win.INFINITE)
}
