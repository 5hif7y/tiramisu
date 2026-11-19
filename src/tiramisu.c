#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <fcntl.h>
#include <io.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "tiramisu.h"
#include "notification.h"
#include "events.h"

/* POSIX -> Win32:
 *   GMainLoop + g_unix_signal_add(SIGINT/SIGTERM)  -> stop event + SetConsoleCtrlHandler
 *   g_bus_own_name(SESSION, org.freedesktop.Notifications)
 *                                                  -> wn_server_start (named pipe, first instance)
 *   getopt("hsjo:")                                -> small parser below (no getopt in the MSVC CRT),
 *                                                     long options from the Vala version added
 */

char *output_format;
int sanitize_output = 0;
int json_output = 0;

static HANDLE main_loop; /* manual-reset event standing in for GMainLoop */

void stop_main_loop(void) {
    SetEvent(main_loop);
}

static BOOL WINAPI console_handler(DWORD type) {
    (void)type; /* Ctrl+C, Ctrl+Break, console closed, logoff, shutdown */
    stop_main_loop();
    return TRUE;
}

static void usage(FILE *out) {
    fprintf(out, "%s\n",
        "tiramisu -[h|s|j|o FORMAT|d DELIM]\n"
        "-h, --help            Help dialog\n"
        "-s, --sanitize        Sanitize output (escape quotes, backslashes, control chars)\n"
        "-j, --json            Output to JSON (implies `-s`)\n"
        "-o, --format FORMAT   Output formatting; keys: #source #icon #id #summary\n"
        "                      #body #actions #hints #timeout\n"
        "-d, --delimiter DELIM Separator for the default format (default: newline)");
}

static char *build_default_format(const char *delimiter) {
    const char *fields[] = DEFAULT_OUTPUT_FIELDS;
    size_t count = sizeof fields / sizeof fields[0], size = 1;
    for (size_t i = 0; i < count; i++)
        size += strlen(fields[i]) + strlen(delimiter);
    char *out = calloc(size, 1);
    for (size_t i = 0; i < count; i++) {
        if (i)
            strcat(out, delimiter);
        strcat(out, fields[i]);
    }
    return out;
}

/* Accepts -o FMT, -oFMT, --format FMT, --format=FMT, and grouped flags (-sj). */
static const char *take_value(int argc, char **argv, int *i, const char *arg, size_t prefix) {
    if (arg[prefix] == '=')
        return arg + prefix + 1;
    if (arg[prefix])
        return arg + prefix;
    if (*i + 1 < argc)
        return argv[++*i];
    fprintf(stderr, "tiramisu: option %s requires a value\n", arg);
    exit(EXIT_FAILURE);
}

int wmain(int argc, wchar_t **wargv) {
    char **argv = calloc(argc + 1, sizeof *argv);
    for (int i = 0; i < argc; i++)
        argv[i] = wn_utf8(wargv[i]);

    const char *delimiter = "\n";

    /* Parse arguments */
    for (int i = 1; i < argc; i++) {
        const char *arg = argv[i];
        if (!strcmp(arg, "--help")) {
            usage(stdout);
            return EXIT_SUCCESS;
        } else if (!strcmp(arg, "--sanitize")) {
            sanitize_output = 1;
        } else if (!strcmp(arg, "--json")) {
            json_output = 1;
        } else if (!strncmp(arg, "--format", 8) && (!arg[8] || arg[8] == '=')) {
            output_format = _strdup(take_value(argc, argv, &i, arg, 8));
        } else if (!strncmp(arg, "--delimiter", 11) && (!arg[11] || arg[11] == '=')) {
            delimiter = take_value(argc, argv, &i, arg, 11);
        } else if (arg[0] == '-' && arg[1] && arg[1] != '-') {
            for (size_t k = 1; arg[k]; k++) {
                switch (arg[k]) {
                    case 'h':
                        usage(stdout);
                        return EXIT_SUCCESS;
                    case 's':
                        sanitize_output = 1;
                        break;
                    case 'j':
                        json_output = 1;
                        break;
                    case 'o':
                        output_format = _strdup(take_value(argc, argv, &i, arg, k + 1));
                        goto next;
                    case 'd':
                        delimiter = take_value(argc, argv, &i, arg, k + 1);
                        goto next;
                    default:
                        fprintf(stderr, "tiramisu: unknown option -%c\n", arg[k]);
                        usage(stderr);
                        return EXIT_FAILURE;
                }
            }
        } else {
            fprintf(stderr, "tiramisu: unexpected argument %s\n", arg);
            usage(stderr);
            return EXIT_FAILURE;
        }
    next:;
    }

    if (json_output) {
        sanitize_output = 1;
        if (!output_format)
            output_format = JSON_OUTPUT_FORMAT;
    }
    if (!output_format)
        output_format = build_default_format(delimiter);

    /* Byte-exact UTF-8 on stdout: no CRLF translation, so pipelines see the
     * same bytes as on Linux (porter-guide module 03). */
    _setmode(_fileno(stdout), _O_BINARY);
    SetConsoleOutputCP(CP_UTF8);

    main_loop = CreateEventW(NULL, TRUE, FALSE, NULL);
    SetConsoleCtrlHandler(console_handler, TRUE);
    events_init();

    char error[512];
    server = wn_server_start(event_handler, NULL, error, sizeof error);
    if (!server) {
        /* name_lost() */
        fprintf(stderr, "%s\n", "bus not acquired; could not own the notifications pipe");
        fprintf(stderr, "%s\n", error);
        return EXIT_FAILURE;
    }

    WaitForSingleObject(main_loop, INFINITE);

    wn_server_stop(server);
    CloseHandle(main_loop);
    return EXIT_SUCCESS;
}
