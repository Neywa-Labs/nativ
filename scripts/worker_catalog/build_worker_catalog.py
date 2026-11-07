#!/usr/bin/env python3
"""Build Sources/Nativ/Resources/WorkerModelCatalog.json from open leaderboards. See README.md."""

from __future__ import annotations

import argparse
import concurrent.futures
import datetime
import hashlib
import http.client
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

MAX_FETCH_ATTEMPTS = 6
HF_API = "https://huggingface.co/api/models"
HF_RESOLVE = "https://huggingface.co/{repo}/resolve/main/{path}"
EEE_RESOLVE = "https://huggingface.co/datasets/evaleval/EEE_datastore/resolve/main/"

CATEGORY_ORDER = [
    "coding",
    "math_reasoning",
    "writing",
    "general",
    "tool_use",
    "knowledge",
    "multilingual",
]
MIN_MODELS_PER_CATEGORY = 5

# One test per category. A model that hasn't taken a category's test gets no score there.
BENCHMARKS = {
    "artificial-analysis-llms": {
        "artificial_analysis.artificial_analysis_intelligence_index": "general",
        "artificial_analysis.artificial_analysis_coding_index": "coding",
        "artificial_analysis.gpqa": "math_reasoning",
        "artificial_analysis.hle": "knowledge",
        "artificial_analysis.tau2": "tool_use",
    },
    "livebench": {"livebench/language": "writing"},
    "global-mmlu-lite": {"Culturally Agnostic": "multilingual"},
}

# Artificial Analysis re-based its indexes during 2026 and stopped publishing them after 27 October,
# so its scores come from each model's newest snapshot on or before that day.
SNAPSHOT_DATES = {"artificial-analysis-llms": "2026-10-27"}

FRACTION_TESTS = {
    "artificial_analysis.gpqa",
    "artificial_analysis.hle",
    "artificial_analysis.tau2",
    "Culturally Agnostic",
}
PERCENT_TESTS = {
    "artificial_analysis.artificial_analysis_intelligence_index",
    "artificial_analysis.artificial_analysis_coding_index",
    "livebench/language",
}

SOURCE_NAMES = {
    "artificial-analysis-llms": "Artificial Analysis (via Every Eval Ever)",
    "livebench": "LiveBench (via Every Eval Ever)",
    "global-mmlu-lite": "Global-MMLU Lite (via Every Eval Ever)",
}

ATTRIBUTION = [
    "Every Eval Ever datastore (MIT)",
    "Artificial Analysis (attribution required)",
    "LiveBench",
    "Global-MMLU Lite",
]

# Penalties are the percent of a score lost to quantization.
ESTIMATES = {
    "bandwidthEfficiency": 0.6,
    "speedBucketFloors": [80, 30, 10],
    "penaltyHighBit": 0.5,
    "penaltySixBit": 1,
    "fourBitPenalties": [
        {"maxParams": 1, "penalty": 15},
        {"maxParams": 2, "penalty": 8},
        {"maxParams": 5, "penalty": 4},
        {"maxParams": 15, "penalty": 2},
        {"maxParams": None, "penalty": 1},
    ],
    "lowBitFactor": 2,
}

TEXT_PIPELINES = {"text-generation", "image-text-to-text"}
QUANT_TOKEN = re.compile(r"^(\d+bit|bf16|fp16|fp32|f16|mxfp\d|nvfp\d|dwq|awq|mlx|qat|optiq|mixed|q\d(_k)?(_[ms])?)$")
FILLER_TOKENS = {"instruct", "it", "chat", "fc", "prompt", "hf", "reasoning", "thinking", "non", "mlx"}
KNOWN_SIZES = {
    "phi-4-mini": 3.8,
    "phi-3.5-mini": 3.8,
    "phi-3-mini": 3.8,
}
DTYPE_BYTES = {
    "F64": 8, "I64": 8, "U64": 8,
    "F32": 4, "I32": 4, "U32": 4,
    "F16": 2, "BF16": 2, "I16": 2, "U16": 2,
    "F8_E4M3": 1, "F8_E5M2": 1, "I8": 1, "U8": 1, "BOOL": 1,
}



def normalize_model_name(name: str) -> str:
    name = name.strip().lower().rstrip("/")
    if "huggingface.co/" in name:
        name = name.split("huggingface.co/", 1)[1]
    name = name.split("/")[-1]
    tokens = [token for token in name.split("-") if token and not QUANT_TOKEN.match(token)]
    return "-".join(tokens)


def parse_variant(repo_id: str) -> tuple[str, float | None]:
    tokens = repo_id.split("/")[-1].lower().split("-")
    bits: float | None = None
    for token in tokens:
        match = re.match(r"^(\d+)bit$", token)
        if match:
            bits = int(match.group(1))
        elif token in ("bf16", "fp16", "f16"):
            bits = 16
        elif token == "fp32":
            bits = 32
        elif re.match(r"^(mx|nv)fp4$", token):
            bits = 4
        elif token == "mxfp8":
            bits = 8
    return normalize_model_name(repo_id), bits


def match_key(name: str) -> str:
    base = normalize_model_name(name).replace(".", "-").replace("_", "-")
    tokens = {token for token in base.split("-") if token and token not in FILLER_TOKENS}
    return "-".join(sorted(tokens))


def params_from_name(name: str) -> tuple[float, float] | None:
    base = normalize_model_name(name)
    for prefix, size in KNOWN_SIZES.items():
        if base.startswith(prefix):
            return (size, size)
    total = None
    active = None
    for token in base.split("-"):
        match = re.match(r"^e?(\d+(?:\.\d+)?)b$", token)
        if match and total is None:
            total = float(match.group(1))
            continue
        match = re.match(r"^a(\d+(?:\.\d+)?)b$", token)
        if match:
            active = float(match.group(1))
    if total is None:
        return None
    return (total, active if active is not None else total)


def kv_bytes_per_token(config: dict) -> int:
    text = config.get("text_config") or config
    layers = int(text.get("num_hidden_layers") or text.get("n_layers") or 0)
    heads = int(text.get("num_attention_heads") or text.get("n_heads") or 0)
    kv_heads = int(text.get("num_key_value_heads") or heads or 0)
    head_dim = text.get("head_dim")
    if not head_dim:
        hidden = int(text.get("hidden_size") or 0)
        head_dim = hidden // heads if heads else 0
    return layers * kv_heads * int(head_dim) * 2 * 2


def weight_bytes(parameters_by_dtype: dict, bits: float, total_params: float | None = None) -> int:
    """Weight bytes from HF's safetensors dtype counts.

    U32 counts are usually logical parameters (bits/8 bytes plus group scales), but some repos
    report packed 32-bit words instead, which shows up as well under half the model's parameters.
    """
    packed_count = sum(int(count) for dtype, count in parameters_by_dtype.items() if dtype.upper() in ("U32", "I32"))
    is_packed = total_params is not None and packed_count < 0.5 * total_params * 1e9
    total = 0
    for dtype, count in parameters_by_dtype.items():
        dtype = dtype.upper()
        if dtype in ("U32", "I32") and bits < 16 and not is_packed:
            total += int(int(count) * (bits / 8 + 0.0625))
        else:
            total += int(count) * DTYPE_BYTES.get(dtype, 2)
    return total


def supports_tools(config: dict) -> bool:
    template = config.get("chat_template_jinja") or (config.get("tokenizer_config") or {}).get("chat_template") or ""
    if isinstance(template, list):
        template = " ".join(str(entry.get("template", "")) for entry in template if isinstance(entry, dict))
    return "tools" in str(template)


def choose_base_id(card_base_model, group_key: str, fallback: str) -> str:
    if isinstance(card_base_model, list):
        card_base_model = card_base_model[0] if card_base_model else None
    if isinstance(card_base_model, str) and card_base_model and match_key(card_base_model) == group_key:
        return card_base_model
    return fallback


ORG_ALIASES = {
    "qwen": {"alibaba"},
    "meta-llama": {"meta"},
    "microsoft": {"azure"},
    "mistralai": {"mistral"},
    "ibm-granite": {"ibm"},
    "lgai-exaone": {"lg", "lgai"},
    "huggingfacetb": {"huggingface"},
    "nvidia": set(),
    "google": set(),
}


def expected_orgs(base_model) -> set:
    if not isinstance(base_model, str) or "/" not in base_model:
        return set()
    org = base_model.split("/", 1)[0].lower()
    return {org} | ORG_ALIASES.get(org, set())


def choose_entry(entries: list, orgs: set) -> dict:
    pool = [entry for entry in entries if entry["org"] in orgs] or entries
    return max(pool, key=lambda entry: (not entry["reasoning"], entry["rank"]))


def _retrieved_at(record: dict) -> float:
    try:
        return float(record.get("retrieved_timestamp") or 0)
    except (TypeError, ValueError):
        return 0.0


def snapshot_day(record: dict) -> str:
    return datetime.datetime.fromtimestamp(_retrieved_at(record), datetime.timezone.utc).date().isoformat()


def pick_snapshot(records: list[dict], cutoff: str | None) -> dict | None:
    eligible = [record for record in records if cutoff is None or snapshot_day(record) <= cutoff]
    return max(eligible, key=_retrieved_at, default=None)


def mark(benchmark: str, raw: float) -> float:
    return round(raw * 100 if benchmark in FRACTION_TESTS else raw, 2)


def category_scores(results: dict[str, dict[str, float]], mapping: dict[str, str]) -> dict[str, dict[str, float]]:
    scores: dict[str, dict[str, float]] = {}
    for test, values in results.items():
        category = mapping.get(test)
        if category is None:
            continue
        benchmark = test.split(":", 1)[-1]
        for model, raw in values.items():
            scores.setdefault(model, {})[category] = mark(benchmark, raw)
    return scores



class Fetcher:
    def __init__(self, cache_dir: Path, token: str | None):
        self.cache_dir = cache_dir
        self.token = token
        cache_dir.mkdir(parents=True, exist_ok=True)

    def _cache_path(self, url: str) -> Path:
        return self.cache_dir / hashlib.sha256(url.encode()).hexdigest()

    def get(self, url: str, use_cache: bool = True, with_headers: bool = False):
        path = self._cache_path(url)
        if use_cache and path.exists() and not with_headers:
            return path.read_bytes()
        request = urllib.request.Request(url, headers={"User-Agent": "nativ-worker-catalog"})
        if self.token:
            request.add_header("Authorization", f"Bearer {self.token}")
        last_error = None
        for attempt in range(MAX_FETCH_ATTEMPTS):
            delay = 2**attempt
            try:
                with urllib.request.urlopen(request, timeout=120) as response:
                    body = response.read()
                    if use_cache:
                        path.write_bytes(body)
                    return (body, dict(response.headers)) if with_headers else body
            except urllib.error.HTTPError as error:
                if error.code == 404:
                    raise
                last_error = error
                retry_after = (error.headers or {}).get("Retry-After")
                if retry_after and str(retry_after).isdigit():
                    delay = int(retry_after)
            except (OSError, http.client.HTTPException) as error:
                last_error = error
            if attempt + 1 < MAX_FETCH_ATTEMPTS:
                time.sleep(delay)
        raise RuntimeError(f"GET {url} failed: {last_error}")

    def json(self, url: str, use_cache: bool = True):
        return json.loads(self.get(url, use_cache=use_cache))


def list_mlx_community(fetcher: Fetcher) -> list[dict]:
    params = [("author", "mlx-community"), ("limit", "1000")]
    for field in ("pipeline_tag", "downloads", "safetensors", "config", "cardData"):
        params.append(("expand[]", field))
    url = HF_API + "?" + urllib.parse.urlencode(params)
    models: list[dict] = []
    while url:
        body, headers = fetcher.get(url, use_cache=False, with_headers=True)
        models.extend(json.loads(body))
        link = headers.get("Link") or headers.get("link") or ""
        match = re.search(r'<([^>]+)>;\s*rel="next"', link)
        url = match.group(1) if match else None
        print(f"  listed {len(models)} mlx-community repos", file=sys.stderr)
    return models


def parallel(function, items, workers: int = 16):
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        return list(pool.map(function, items))



def collect_variants(models: list[dict]) -> dict[str, list[dict]]:
    groups: dict[str, list[dict]] = {}
    for model in models:
        if model.get("pipeline_tag") not in TEXT_PIPELINES:
            continue
        repo_id = model["id"]
        base_name, bits = parse_variant(repo_id)
        config = model.get("config") or {}
        quantization = config.get("quantization_config") or config.get("quantization") or {}
        if bits is None:
            bits = quantization.get("bits") or 16
        if not config:
            # The API omits config for some repos; skip them rather than guess tool support.
            continue
        safetensors = (model.get("safetensors") or {}).get("parameters") or {}
        groups.setdefault(match_key(base_name), []).append({
            "repoID": repo_id,
            "baseName": base_name,
            "bits": float(bits),
            "safetensors": safetensors,
            "downloads": int(model.get("downloads") or 0),
            "supportsTools": supports_tools(config),
            "pipeline": model.get("pipeline_tag"),
            "cardBaseModel": (model.get("cardData") or {}).get("base_model"),
        })
    return groups


def directory_of(row: dict) -> str:
    return "/".join(row["legacy_path"].split("/")[2:4])


def eee_names(record: dict, legacy_path: str) -> list[str]:
    info = record.get("model_info") or {}
    details = info.get("additional_details") or {}
    names = [info.get("id"), info.get("name"), details.get("model_link"), details.get("model_registry_id")]
    names.append("/".join(legacy_path.split("/")[2:4]))
    return [name for name in names if isinstance(name, str) and name]


def is_reasoning_variant(name: str) -> bool:
    lowered = re.sub(r"non[- _]?reasoning", "", name.lower())
    return "reasoning" in lowered or "thinking" in lowered


def collect_scores(fetcher: Fetcher, catalog_orgs: dict) -> dict[str, dict[str, dict]]:
    catalog_keys = set(catalog_orgs)
    candidates: dict[tuple[str, str], list] = {}
    for collection, mapping in BENCHMARKS.items():
        try:
            index = fetcher.get(EEE_RESOLVE + f"flat/indexes/by_collection/{collection}.jsonl").decode()
        except Exception as error:
            print(f"  skip {collection}: {error}", file=sys.stderr)
            continue
        rows = []
        for line in index.splitlines():
            row = json.loads(line)
            if match_key(directory_of(row)) in catalog_keys:
                rows.append(row)

        def load(row):
            try:
                return row, fetcher.json(EEE_RESOLVE + row["object_path"])
            except Exception:
                return row, None

        snapshots: dict[str, list[dict]] = {}
        for row, record in parallel(load, rows):
            if record:
                snapshots.setdefault(directory_of(row), []).append(dict(record, _row=row))
        chosen = [pick_snapshot(records, SNAPSHOT_DATES.get(collection)) for records in snapshots.values()]

        for record in filter(None, chosen):
            row = record["_row"]
            names = eee_names(record, row["legacy_path"])
            keys = {match_key(name) for name in names} & catalog_keys
            if not keys:
                continue
            model_id = (record.get("model_info") or {}).get("id") or ""
            org = (model_id.split("/", 1)[0] if "/" in model_id else row["legacy_path"].split("/")[2]).lower()
            reasoning = any(is_reasoning_variant(name) for name in names)
            for result in record.get("evaluation_results") or []:
                config = result.get("metric_config") or {}
                benchmark = None
                for candidate in (config.get("metric_id"), result.get("evaluation_name")):
                    if candidate in mapping:
                        benchmark = candidate
                        break
                score = (result.get("score_details") or {}).get("score")
                if benchmark is None or not isinstance(score, (int, float)):
                    continue
                entry = {
                    "org": org,
                    "reasoning": reasoning,
                    "rank": -float(score) if config.get("lower_is_better") else float(score),
                    "raw": float(score),
                    "source": SOURCE_NAMES.get(collection, collection),
                    "url": EEE_RESOLVE + row["object_path"],
                }
                for key in keys:
                    candidates.setdefault((f"{collection}:{benchmark}", key), []).append(entry)
        print(f"  {collection}: {len(snapshots)} models from {len(rows)} snapshots", file=sys.stderr)

    results: dict[str, dict[str, dict]] = {}
    for (benchmark_id, key), entries in candidates.items():
        results.setdefault(benchmark_id, {})[key] = choose_entry(entries, catalog_orgs.get(key, set()))
    return results


def fetch_kv_bytes(fetcher: Fetcher, repo_id: str) -> int | None:
    try:
        config = fetcher.json(HF_RESOLVE.format(repo=repo_id, path="config.json"))
    except Exception:
        return None
    value = kv_bytes_per_token(config)
    return value or None


def build(fetcher: Fetcher) -> tuple[dict, str]:
    print("Listing mlx-community models...", file=sys.stderr)
    models = list_mlx_community(fetcher)
    groups = collect_variants(models)
    groups = {key: variants for key, variants in groups.items() if params_from_name(variants[0]["baseName"])}
    print(f"  {len(groups)} base models with a parseable size", file=sys.stderr)

    print("Collecting leaderboard scores...", file=sys.stderr)
    catalog_orgs = {}
    for key, variants in groups.items():
        top = max(variants, key=lambda v: v["downloads"])
        card = top["cardBaseModel"][0] if isinstance(top["cardBaseModel"], list) and top["cardBaseModel"] else top["cardBaseModel"]
        catalog_orgs[key] = expected_orgs(choose_base_id(card, key, ""))
    raw_scores = collect_scores(fetcher, catalog_orgs)
    mapping = {
        f"{collection}:{benchmark}": category
        for collection, benchmarks in BENCHMARKS.items()
        for benchmark, category in benchmarks.items()
    }
    by_model = category_scores(
        {benchmark: {key: entry["raw"] for key, entry in entries.items()} for benchmark, entries in raw_scores.items()},
        mapping,
    )

    counts = {category: sum(1 for scores in by_model.values() if category in scores) for category in CATEGORY_ORDER}
    categories = [c for c in CATEGORY_ORDER if counts[c] >= MIN_MODELS_PER_CATEGORY or c == "general"]

    scored_keys = [key for key in groups if any(c in by_model.get(key, {}) for c in categories)]
    representatives = {key: max(groups[key], key=lambda v: v["downloads"])["repoID"] for key in scored_keys}
    print(f"Fetching config.json for {len(scored_keys)} base models...", file=sys.stderr)
    kv_values = dict(zip(scored_keys, parallel(lambda key: fetch_kv_bytes(fetcher, representatives[key]), scored_keys)))

    catalog_models = []
    for key in sorted(scored_keys):
        variants = groups[key]
        top = max(variants, key=lambda v: v["downloads"])
        total, active = params_from_name(top["baseName"])
        scores = {}
        for category in categories:
            if category not in by_model.get(key, {}):
                continue
            sources = [
                {
                    "benchmark": benchmark.split(":", 1)[1],
                    "raw": round(entries[key]["raw"], 4),
                    "source": entries[key]["source"],
                    "url": entries[key]["url"],
                }
                for benchmark, entries in raw_scores.items()
                if mapping.get(benchmark) == category and key in entries
            ]
            scores[category] = {"score": by_model[key][category], "sources": sources}
        catalog_models.append({
            "baseID": choose_base_id(top["cardBaseModel"], key, top["baseName"]),
            "totalParams": total,
            "activeParams": active,
            "kvBytesPerToken": kv_values.get(key) or 147456,
            "modality": "vision" if any(v["pipeline"] == "image-text-to-text" for v in variants) else "text",
            "scores": scores,
            "variants": [
                {
                    "repoID": v["repoID"],
                    "bits": v["bits"],
                    "sizeBytes": weight_bytes(v["safetensors"], v["bits"], total) or int(total * 1e9 * v["bits"] / 8),
                    "downloads": v["downloads"],
                    "supportsTools": v["supportsTools"],
                }
                for v in sorted(variants, key=lambda v: -v["downloads"])
            ],
        })

    catalog = {
        "version": 1,
        "generated": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d"),
        "categories": categories,
        "attribution": ATTRIBUTION,
        "estimates": ESTIMATES,
        "models": catalog_models,
    }
    report = coverage_report(models, groups, scored_keys, counts, categories, catalog_models)
    return catalog, report


def coverage_report(models, groups, scored_keys, counts, categories, catalog_models) -> str:
    text_repos = [m for m in models if m.get("pipeline_tag") in TEXT_PIPELINES]
    covered = {v["repoID"] for key in scored_keys for v in groups[key]}
    total_downloads = sum(int(m.get("downloads") or 0) for m in text_repos) or 1
    covered_downloads = sum(int(m.get("downloads") or 0) for m in text_repos if m["id"] in covered)
    lines = [
        f"mlx-community text/vision repos: {len(text_repos)}",
        f"repos in catalog: {len(covered)} ({100 * len(covered) / max(1, len(text_repos)):.1f}%)",
        f"download-weighted coverage: {100 * covered_downloads / total_downloads:.1f}%",
        f"base models in catalog: {len(catalog_models)}",
        "scored base models per category: " + ", ".join(f"{c}={counts[c]}" for c in CATEGORY_ORDER),
        "categories kept: " + ", ".join(categories),
        "",
        "Top uncovered repos by downloads:",
    ]
    uncovered = sorted((m for m in text_repos if m["id"] not in covered), key=lambda m: -int(m.get("downloads") or 0))
    lines += [f"  {m['id']} ({m.get('downloads')})" for m in uncovered[:40]]
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--report", type=Path)
    parser.add_argument("--cache-dir", type=Path, default=Path.home() / ".cache" / "nativ-worker-catalog")
    args = parser.parse_args(argv)
    fetcher = Fetcher(args.cache_dir, os.environ.get("HF_TOKEN"))
    catalog, report = build(fetcher)
    args.out.write_text(json.dumps(catalog, indent=1, sort_keys=False) + "\n")
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(report)
    print(report)
    return 0


if __name__ == "__main__":
    sys.exit(main())
