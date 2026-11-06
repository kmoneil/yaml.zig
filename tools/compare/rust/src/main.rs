// rustbench MODE RUNS FILE: MODE events (saphyr-parser), value (saphyr
// Yaml), typed (serde_yaml), typed-saphyr (serde-saphyr), or read. One
// warm-up, RUNS timed runs, the median in ms.
use saphyr::LoadableYamlNode;
use serde::Deserialize;
use std::collections::HashMap;
use std::time::Instant;

#[allow(dead_code)]
#[derive(Deserialize)]
struct Record {
    name: String,
    id: u32,
    ratio: f64,
    enabled: bool,
    tags: Vec<String>,
    owner: Option<String>,
    description: String,
    ports: Vec<u16>,
    env: HashMap<String, String>,
}

fn run(mode: &str, text: &str) -> usize {
    match mode {
        "events" => saphyr_parser::Parser::new_from_str(text).map(|e| e.unwrap()).count(),
        "value" => saphyr::Yaml::load_from_str(text).unwrap().len(),
        "typed" => serde_yaml::from_str::<Vec<Record>>(text).unwrap().len(),
        "typed-saphyr" => {
            // Its default budget (250,000 nodes) refuses the 4.9 MB document.
            let mut budget = serde_saphyr::Budget::default();
            budget.max_nodes = 10_000_000;
            budget.max_events = 10_000_000;
            let mut options = serde_saphyr::Options::default();
            options.budget = Some(budget);
            serde_saphyr::from_str_with_options::<Vec<Record>>(text, options).unwrap().len()
        }
        _ => panic!("mode"),
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let runs: usize = args[2].parse().unwrap();
    let text = std::fs::read_to_string(&args[3]).unwrap();
    if args[1] == "read" {
        return;
    }
    let mut sink = run(&args[1], &text);
    let mut times = Vec::new();
    for _ in 0..runs {
        let t = Instant::now();
        sink += run(&args[1], &text);
        times.push(t.elapsed().as_secs_f64() * 1e3);
    }
    std::hint::black_box(sink);
    times.sort_by(|a, b| a.partial_cmp(b).unwrap());
    println!("{:.1}", times[runs / 2]);
}
