// ryml MODE RUNS FILE: MODE tree (parse_in_arena, a fresh tree a run)
// or read. One warm-up, RUNS timed runs, the median in ms.
#define RYML_SINGLE_HDR_DEFINE_NOW
#include "ryml.hpp"
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

static size_t tree(const std::string &text) {
    ryml::Tree t = ryml::parse_in_arena(ryml::to_csubstr(text));
    return t.num_children(t.root_id());
}

int main(int argc, char **argv) {
    if (argc < 4) return 2;
    int runs = std::atoi(argv[2]);
    std::ifstream in(argv[3], std::ios::binary);
    std::string text((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    if (!std::strcmp(argv[1], "read")) return 0;
    volatile size_t sink = tree(text);
    std::vector<double> times;
    for (int i = 0; i < runs; i++) {
        auto t = std::chrono::steady_clock::now();
        sink += tree(text);
        times.push_back(std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t).count());
    }
    std::sort(times.begin(), times.end());
    std::printf("%.1f\n", times[runs / 2]);
    return 0;
}
