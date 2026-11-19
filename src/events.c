#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

#include "events.h"
#include "tiramisu.h"
#include "notification.h"

/* GDBus dispatched every method call on the GMainContext thread; the pipe
 * server calls us from one thread per client, so the id counter and stdout
 * need a lock. */
static CRITICAL_SECTION lock;
static unsigned int id = 0;
wn_server *server = NULL;

void events_init(void) {
    InitializeCriticalSection(&lock);
}

void event_handler(wn_conn *connection, char **fields, size_t n_fields, void *data) {
    (void)data;
    const char *label = fields[0];

    if (!strcmp(label, "GetServerInformation")) {
        wn_reply(connection, "OK\ttiramisu\tSweets\t" TIRAMISU_VERSION "\t" WN_SPEC_VERSION);
    } else if (!strcmp(label, "GetCapabilities")) {
        wn_reply(connection, "OK\tbody\tactions\ticon-static");
    } else if (!strcmp(label, "CloseNotification")) {
        /* Nothing is on screen, but the spec says the server must emit
         * NotificationClosed(id, 3); clients like `notify-send -w` wait for it. */
        unsigned long closed = n_fields > 1 ? strtoul(fields[1], NULL, 10) : 0;
        wn_reply_ok(connection);
        wn_emit_closed(server, (uint32_t)closed, WN_CLOSE_CLOSED);
    } else if (!strcmp(label, "Notify")) {
        wn_notify raw;
        if (wn_parse_notify(fields, n_fields, &raw)) {
            wn_reply_err(connection, "malformed Notify");
            return;
        }

        EnterCriticalSection(&lock);
        /* 1.x/2.x C: always ++id (ignored replaces_id).
         * Vala: honours replaces_id. We keep the Vala semantics. */
        unsigned int assigned = raw.replaces_id ? raw.replaces_id : ++id;

        notification_t notification;
        hydrate_notification(&notification, &raw, assigned);

        char *output = _strdup(output_format);
        interpolate_output_string(&output, notification);
        fwrite(output, 1, strlen(output), stdout);
        fputc('\n', stdout);
        fflush(stdout); /* "vital" (commit 3cbe502) */
        LeaveCriticalSection(&lock);

        free(output);
        free_notification(&notification);
        wn_notify_free(&raw);

        char reply[32];
        snprintf(reply, sizeof reply, "OK\t%u", assigned);
        wn_reply(connection, reply);
    } else {
        print("Unhandled(%s)", label);
        wn_reply_err(connection, "unknown method");
    }
}
