// gobench MODE RUNS FILE: MODE node (a yaml.Node tree), any (generic
// values), typed ([]Record), or read. One warm-up, RUNS timed runs, the
// median in ms; RUNS 0, one run alone, its time.
package main

import (
	"fmt"
	"os"
	"sort"
	"strconv"
	"time"

	"gopkg.in/yaml.v3"
)

type Record struct {
	Name        string            `yaml:"name"`
	ID          uint32            `yaml:"id"`
	Ratio       float64           `yaml:"ratio"`
	Enabled     bool              `yaml:"enabled"`
	Tags        []string          `yaml:"tags"`
	Owner       *string           `yaml:"owner"`
	Description string            `yaml:"description"`
	Ports       []uint16          `yaml:"ports"`
	Env         map[string]string `yaml:"env"`
}

var sink int

func run(mode string, text []byte) {
	switch mode {
	case "node":
		var n yaml.Node
		if err := yaml.Unmarshal(text, &n); err != nil {
			panic(err)
		}
		sink += len(n.Content)
	case "any":
		var v any
		if err := yaml.Unmarshal(text, &v); err != nil {
			panic(err)
		}
		sink += len(v.([]any))
	case "typed":
		var r []Record
		if err := yaml.Unmarshal(text, &r); err != nil {
			panic(err)
		}
		sink += len(r)
	}
}

func main() {
	runs, _ := strconv.Atoi(os.Args[2])
	text, err := os.ReadFile(os.Args[3])
	if err != nil {
		panic(err)
	}
	if os.Args[1] == "read" {
		return
	}
	if runs == 0 {
		t := time.Now()
		run(os.Args[1], text)
		fmt.Printf("%.1f\n", float64(time.Since(t).Microseconds())/1e3)
		return
	}
	run(os.Args[1], text)
	times := make([]float64, runs)
	for i := range times {
		t := time.Now()
		run(os.Args[1], text)
		times[i] = float64(time.Since(t).Microseconds()) / 1e3
	}
	sort.Float64s(times)
	fmt.Printf("%.1f\n", times[runs/2])
}
