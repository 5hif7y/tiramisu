#pragma once

#include <stdio.h>
#include <string.h>

#define TIRAMISU_VERSION "2.0-win"

extern char *output_format;
extern int sanitize_output;
extern int json_output;

#ifdef DEBUG
#define print(...) fprintf(stderr, __VA_ARGS__);
#else
#define print(...) (void)(__VA_ARGS__);
#endif

/* Default: one field per line, as in 1.x/2.x. `-d` changes the separator
 * (the 1.x `-d delimiter` option, folded into the format-string world). */
#define DEFAULT_OUTPUT_FIELDS { "#source", "#icon", "#id", "#summary", \
    "#body", "#actions", "#hints", "#timeout" }

/* Valid JSON (the 2021-10-06 C version emitted single quotes). Hints and
 * actions expand to JSON objects, not to strings. */
#define JSON_OUTPUT_FORMAT "{\"source\": \"#source\", " \
    "\"id\": #id, " \
    "\"summary\": \"#summary\", " \
    "\"body\": \"#body\", " \
    "\"icon\": \"#icon\", " \
    "\"actions\": #actions, " \
    "\"hints\": #hints, " \
    "\"timeout\": #timeout}"

void stop_main_loop(void);
