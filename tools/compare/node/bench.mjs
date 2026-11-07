// node bench.mjs MODE RUNS FILE: MODE load (js-yaml load to JS values) or read.
// One warm-up, RUNS timed runs, the median in ms; RUNS 0, one run alone,
// its time.
import { readFileSync } from "node:fs";
import { load } from "js-yaml";
const [mode, runsArg, file] = process.argv.slice(2);
const runs = Number(runsArg);
const text = readFileSync(file, "utf8");
if (mode !== "read" && runs === 0) {
  const t = performance.now();
  load(text);
  console.log((performance.now() - t).toFixed(1));
} else if (mode !== "read") {
  let sink = load(text).length;
  const times = [];
  for (let i = 0; i < runs; i++) {
    const t = performance.now();
    sink += load(text).length;
    times.push(performance.now() - t);
  }
  times.sort((a, b) => a - b);
  console.log(times[Math.floor(runs / 2)].toFixed(1));
}
