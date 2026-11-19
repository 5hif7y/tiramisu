#pragma once

#include "wnotify.h"

/* GDBus vtable -> wnotify request callback (runs on a pipe connection thread). */
void event_handler(wn_conn *connection, char **fields, size_t n_fields, void *data);
void events_init(void);

extern wn_server *server;
