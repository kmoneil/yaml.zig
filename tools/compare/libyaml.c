// libyaml MODE RUNS FILE: MODE events (parse to events) or load (a
// document tree), or read. One warm-up, RUNS timed runs, the median in ms;
// RUNS 0, one run alone, its time.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <yaml.h>

static size_t events(const unsigned char *text, size_t len) {
    yaml_parser_t p;
    yaml_event_t ev;
    size_t n = 0;
    yaml_parser_initialize(&p);
    yaml_parser_set_input_string(&p, text, len);
    for (;;) {
        if (!yaml_parser_parse(&p, &ev)) { fprintf(stderr, "parse error\n"); exit(1); }
        int end = ev.type == YAML_STREAM_END_EVENT;
        yaml_event_delete(&ev);
        n++;
        if (end) break;
    }
    yaml_parser_delete(&p);
    return n;
}

static size_t load(const unsigned char *text, size_t len) {
    yaml_parser_t p;
    yaml_document_t doc;
    size_t n = 0;
    yaml_parser_initialize(&p);
    yaml_parser_set_input_string(&p, text, len);
    for (;;) {
        if (!yaml_parser_load(&p, &doc)) { fprintf(stderr, "load error\n"); exit(1); }
        yaml_node_t *root = yaml_document_get_root_node(&doc);
        if (!root) { yaml_document_delete(&doc); break; }
        n += root->data.sequence.items.top - root->data.sequence.items.start;
        yaml_document_delete(&doc);
    }
    yaml_parser_delete(&p);
    return n;
}

static double now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}

static int cmp(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

int main(int argc, char **argv) {
    if (argc < 4) return 2;
    int runs = atoi(argv[2]);
    FILE *f = fopen(argv[3], "rb");
    fseek(f, 0, SEEK_END);
    size_t len = ftell(f);
    fseek(f, 0, SEEK_SET);
    unsigned char *text = malloc(len);
    if (fread(text, 1, len, f) != len) return 1;
    fclose(f);
    if (!strcmp(argv[1], "read")) return 0;
    size_t (*fn)(const unsigned char *, size_t) = !strcmp(argv[1], "events") ? events : load;
    if (runs == 0) {
        double t = now_ms();
        volatile size_t sink = fn(text, len);
        printf("%.1f\n", now_ms() - t);
        return 0;
    }
    volatile size_t sink = fn(text, len);
    double times[64];
    for (int i = 0; i < runs; i++) {
        double t = now_ms();
        sink += fn(text, len);
        times[i] = now_ms() - t;
    }
    qsort(times, runs, sizeof times[0], cmp);
    printf("%.1f\n", times[runs / 2]);
    return 0;
}
