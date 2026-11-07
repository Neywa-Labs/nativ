# Worker model catalog

`build_worker_catalog.py` builds `Sources/Nativ/Resources/WorkerModelCatalog.json`, which Nativ uses
to pick worker models when worker sub-agents are on. The app never fetches scores; run the script and
commit its output.

```sh
python3 scripts/worker_catalog/build_worker_catalog.py --out Sources/Nativ/Resources/WorkerModelCatalog.json
```

It uses only the standard library and caches downloads in `~/.cache/nativ-worker-catalog`. The first
run downloads about 11,000 leaderboard snapshots and takes a couple of hours. Set `HF_TOKEN` if you hit
rate limits.

Each category uses one test from the [Every Eval Ever](https://huggingface.co/datasets/evaleval/EEE_datastore)
datastore (`BENCHMARKS` in the script), and a model's score is its mark out of 100 on that test. Models
that haven't taken a category's test get no score there. Scores come from Artificial Analysis
(attribution required), LiveBench and Global-MMLU Lite, through Every Eval Ever (MIT).
