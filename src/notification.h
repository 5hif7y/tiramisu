#pragma once

#include "wnotify.h"

/* Was a view over the GVariant parameters; now a view over a parsed wnotify
 * Notify request (same fields, same order as the D-Bus signature). */
typedef struct {
    char *source;
    char *summary;
    char *body;
    char *icon;

    unsigned int id;       /* id assigned by the daemon (not replaces_id) */
    int timeout;

    const wn_notify *raw;  /* actions + typed hints */
} notification_t;

void hydrate_notification(notification_t *, const wn_notify *, unsigned int id);
void free_notification(notification_t *);
void interpolate_output_string(char **, notification_t);
