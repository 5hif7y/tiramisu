#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#include "notification.h"
#include "tiramisu.h"

/* Pain. Suffering. (Less of it: GVariant is gone, hints arrive typed as text.)
 *
 * Feature union of every tiramisu generation:
 *   1.x C  (2020): JSON with hints/actions as objects, typed hint values,
 *                  escaping of '"' and '\n', -d delimiter
 *   2.x C  (2021): -o format string, -s, -j, CSV hints, image-data with
 *                  length validation, base64
 *   2.x Vala     : long options, replaces_id, \r escaping, quoted string
 *                  hints in CSV, icon in JSON
 * Fixes on top: valid JSON (backslash + control chars escaped), #id is the
 * id actually assigned, and interpolation is single-pass so a summary that
 * contains "#body" is not expanded again.
 */

static char *strsanitize(const char *string);

/* ---- small growable string ---------------------------------------------- */

typedef struct { char *s; size_t len, cap; } str_t;

static void str_add(str_t *b, const char *s, size_t n) {
    if (b->len + n + 1 > b->cap) {
        b->cap = (b->len + n + 1) * 2;
        b->s = realloc(b->s, b->cap);
    }
    memcpy(b->s + b->len, s, n);
    b->len += n;
    b->s[b->len] = 0;
}

static void str_cat(str_t *b, const char *s) { str_add(b, s, strlen(s)); }

static char *str_take(str_t *b) {
    if (!b->s)
        return _strdup("");
    return b->s;
}

/* ---- hydrate ------------------------------------------------------------ */

static char *maybe_sanitize(const char *s) {
    return sanitize_output ? strsanitize(s) : _strdup(s);
}

void hydrate_notification(notification_t *notification, const wn_notify *raw, unsigned int id) {
    notification->source  = maybe_sanitize(raw->app_name);
    notification->icon    = maybe_sanitize(raw->app_icon);
    notification->summary = maybe_sanitize(raw->summary);
    notification->body    = maybe_sanitize(raw->body);
    notification->id      = id;
    notification->timeout = raw->expire_timeout;
    notification->raw     = raw;
}

void free_notification(notification_t *notification) {
    free(notification->source);
    free(notification->icon);
    free(notification->summary);
    free(notification->body);
}

/* ---- hints -------------------------------------------------------------- */

/* image-data / image_data / icon_data: "w:h:stride:alpha:bps:channels:b64".
 * Validate the pixel buffer length like the 2.x C code did. */
static int image_is_valid(const char *value) {
    int w, h, stride, alpha, bps, channels, consumed = 0;
    if (sscanf(value, "%d:%d:%d:%d:%d:%d:%n", &w, &h, &stride, &alpha, &bps, &channels, &consumed) != 6 || !consumed)
        return 0;
    if (w <= 0 || h <= 0 || stride <= 0 || bps <= 0 || channels <= 0)
        return 0;
    size_t real_length;
    unsigned char *pixels = wn_base64_decode(value + consumed, &real_length);
    free(pixels);
    size_t pixel_stride = ((size_t)channels * bps + 7) / 8;
    size_t expected_length = (size_t)(h - 1) * stride + (size_t)w * pixel_stride;
    return expected_length == real_length;
}

static int is_number(const char *s) {
    char *end;
    if (!*s)
        return 0;
    double d = strtod(s, &end);
    return !*end && isfinite(d);
}

static char *create_hint_csv_string(const wn_notify *raw) {
    str_t out = {0};
    const char *separator = "";

    for (size_t i = 0; i < raw->n_hints; i++) {
        const wn_hint *hint = &raw->hints[i];
        char *value;

        if (!strcmp(hint->type, "s")) {
            /* Vala: strings quoted with ''. (Vala also escaped the inside
             * unconditionally and again under -s: double escaping. Once.) */
            size_t n = strlen(hint->value) + 3;
            value = malloc(n);
            snprintf(value, n, "'%s'", hint->value);
        } else if (!strcmp(hint->type, "image")) {
            if (!image_is_valid(hint->value))
                continue; /* 2.x C: skip images whose length does not match */
            value = _strdup(hint->value);
        } else {
            value = _strdup(hint->value);
        }

        char *key = maybe_sanitize(hint->name);
        char *val = maybe_sanitize(value);
        str_cat(&out, separator);
        str_cat(&out, key);
        str_cat(&out, "=");
        str_cat(&out, val);
        separator = ",";
        free(key);
        free(val);
        free(value);
    }
    return str_take(&out);
}

static char *create_hint_json_string(const wn_notify *raw) {
    str_t out = {0};
    str_cat(&out, "{");

    for (size_t i = 0, emitted = 0; i < raw->n_hints; i++) {
        const wn_hint *hint = &raw->hints[i];
        const char *t = hint->type;
        int quoted;

        if (!strcmp(t, "image")) {
            if (!image_is_valid(hint->value))
                continue;
            quoted = 1;
        } else if (!strcmp(t, "b")) {
            quoted = strcmp(hint->value, "true") && strcmp(hint->value, "false");
        } else if (strlen(t) == 1 && strchr("ynqiuxtd", t[0])) {
            quoted = !is_number(hint->value);
        } else {
            quoted = 1;
        }

        char *key = strsanitize(hint->name);
        char *val = strsanitize(hint->value);
        if (emitted++)
            str_cat(&out, ", ");
        str_cat(&out, "\"");
        str_cat(&out, key);
        str_cat(&out, "\": ");
        if (quoted)
            str_cat(&out, "\"");
        str_cat(&out, val);
        if (quoted)
            str_cat(&out, "\"");
        free(key);
        free(val);
    }
    str_cat(&out, "}");
    return str_take(&out);
}

/* ---- actions -------------------------------------------------------------
 * CSV: "Label=key,Label=key" as documented in the C-era README
 *      ("Show INBOX=default").
 * JSON: {"key": "Label"} (1.x had label->key; keys are the unique side). */

static char *create_action_csv_string(const wn_notify *raw) {
    str_t out = {0};
    for (size_t i = 0; i + 1 < raw->n_actions; i += 2) {
        char *key = maybe_sanitize(raw->actions[i]);
        char *label = maybe_sanitize(raw->actions[i + 1]);
        if (i)
            str_cat(&out, ",");
        str_cat(&out, label);
        str_cat(&out, "=");
        str_cat(&out, key);
        free(key);
        free(label);
    }
    return str_take(&out);
}

static char *create_action_json_string(const wn_notify *raw) {
    str_t out = {0};
    str_cat(&out, "{");
    for (size_t i = 0; i + 1 < raw->n_actions; i += 2) {
        char *key = strsanitize(raw->actions[i]);
        char *label = strsanitize(raw->actions[i + 1]);
        if (i)
            str_cat(&out, ", ");
        str_cat(&out, "\"");
        str_cat(&out, key);
        str_cat(&out, "\": \"");
        str_cat(&out, label);
        str_cat(&out, "\"");
        free(key);
        free(label);
    }
    str_cat(&out, "}");
    return str_take(&out);
}

/* ---- interpolation ------------------------------------------------------ */

void interpolate_output_string(char **format_string, notification_t notification) {
    char id_buffer[16], timeout_buffer[16];
    snprintf(id_buffer, sizeof id_buffer, "%u", notification.id);
    snprintf(timeout_buffer, sizeof timeout_buffer, "%d", notification.timeout);

    char *hints = json_output ? create_hint_json_string(notification.raw)
                              : create_hint_csv_string(notification.raw);
    char *actions = json_output ? create_action_json_string(notification.raw)
                                : create_action_csv_string(notification.raw);

    const struct { const char *key; const char *value; } table[] = {
        { "#source",  notification.source },
        { "#icon",    notification.icon },
        { "#id",      id_buffer },
        { "#summary", notification.summary },
        { "#body",    notification.body },
        { "#actions", actions },
        { "#hints",   hints },
        { "#timeout", timeout_buffer },
    };

    /* Single pass over the template: replacement text is never rescanned. */
    str_t out = {0};
    const char *p = *format_string;
    while (*p) {
        size_t matched = 0;
        if (*p == '#') {
            for (size_t i = 0; i < sizeof table / sizeof table[0]; i++) {
                size_t n = strlen(table[i].key);
                if (!strncmp(p, table[i].key, n)) {
                    str_cat(&out, table[i].value);
                    matched = n;
                    break;
                }
            }
        }
        if (matched) {
            p += matched;
        } else {
            str_add(&out, p, 1);
            p++;
        }
    }

    free(hints);
    free(actions);
    free(*format_string);
    *format_string = str_take(&out);
}

/* ---- sanitize ------------------------------------------------------------
 * 2.x C escaped only '"'; 1.x also '\n'; Vala '"', '\r', '\n' ("ideally all
 * control sequences"). Here: everything JSON requires. */

static char *strsanitize(const char *string) {
    str_t out = {0};
    char esc[8];
    for (const unsigned char *p = (const unsigned char *)string; *p; p++) {
        switch (*p) {
            case '"':  str_cat(&out, "\\\""); break;
            case '\\': str_cat(&out, "\\\\"); break;
            case '\n': str_cat(&out, "\\n"); break;
            case '\r': str_cat(&out, "\\r"); break;
            case '\t': str_cat(&out, "\\t"); break;
            default:
                if (*p < 0x20) {
                    snprintf(esc, sizeof esc, "\\u%04x", *p);
                    str_cat(&out, esc);
                } else {
                    str_add(&out, (const char *)p, 1);
                }
        }
    }
    return str_take(&out);
}
