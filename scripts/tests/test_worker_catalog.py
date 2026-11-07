import datetime
import http.client
import importlib.util
from pathlib import Path
import socket
import tempfile
import unittest
from unittest import mock
import urllib.error


spec = importlib.util.spec_from_file_location(
    "build_worker_catalog",
    Path(__file__).parents[1] / "worker_catalog/build_worker_catalog.py",
)
catalog = importlib.util.module_from_spec(spec)
spec.loader.exec_module(catalog)


class ParseVariantTests(unittest.TestCase):
    def test_parse_variant(self):
        self.assertEqual(catalog.parse_variant("mlx-community/Qwen3-4B-4bit"), ("qwen3-4b", 4))
        self.assertEqual(
            catalog.parse_variant("mlx-community/Qwen3-4B-Instruct-2507-4bit-DWQ"),
            ("qwen3-4b-instruct-2507", 4),
        )
        self.assertEqual(
            catalog.parse_variant("mlx-community/Llama-3.2-3B-Instruct-bf16"),
            ("llama-3.2-3b-instruct", 16),
        )
        self.assertEqual(catalog.parse_variant("mlx-community/gemma-3-4b-it-8bit"), ("gemma-3-4b-it", 8))
        self.assertEqual(catalog.parse_variant("mlx-community/Some-Model"), ("some-model", None))

    def test_match_key_ignores_order_punctuation_and_filler(self):
        self.assertEqual(catalog.match_key("Qwen3-1.7B"), catalog.match_key("qwen/qwen3-1-7b-fc"))
        self.assertEqual(catalog.match_key("qwen3-4b-instruct-2507"), catalog.match_key("alibaba/qwen3-4b-2507-instruct"))
        self.assertEqual(catalog.match_key("gemma-3-4b-it"), catalog.match_key("google/gemma-3-4b-it-prompt"))
        self.assertNotEqual(catalog.match_key("qwen3-4b"), catalog.match_key("qwen3-4b-instruct-2507"))

    def test_params_from_name(self):
        self.assertEqual(catalog.params_from_name("qwen3-1.7b"), (1.7, 1.7))
        self.assertEqual(catalog.params_from_name("qwen3-30b-a3b-instruct-2507"), (30.0, 3.0))
        self.assertEqual(catalog.params_from_name("gemma-3n-e4b-it"), (4.0, 4.0))
        self.assertEqual(catalog.params_from_name("phi-4-mini-instruct"), (3.8, 3.8))
        self.assertIsNone(catalog.params_from_name("mystery-model"))


class BaseIDTests(unittest.TestCase):
    def test_card_base_model_is_used_only_when_it_matches_the_group(self):
        key = catalog.match_key("gemma-3-4b-it")
        self.assertEqual(catalog.choose_base_id("google/gemma-3-4b-it", key, "gemma-3-4b-it"), "google/gemma-3-4b-it")
        self.assertEqual(catalog.choose_base_id("OpenGVLab/InternVL3-1B-Instruct", key, "gemma-3-4b-it"), "gemma-3-4b-it")
        self.assertEqual(catalog.choose_base_id(["google/gemma-3-4b-it"], key, "gemma-3-4b-it"), "google/gemma-3-4b-it")
        self.assertEqual(catalog.choose_base_id(None, key, "gemma-3-4b-it"), "gemma-3-4b-it")


class OrgPreferenceTests(unittest.TestCase):
    def test_expected_org_beats_a_higher_scoring_copy(self):
        entries = [
            {"org": "jebish7", "reasoning": False, "rank": 90.0},
            {"org": "meta-llama", "reasoning": False, "rank": 60.0},
        ]
        self.assertEqual(catalog.choose_entry(entries, {"meta-llama", "meta"})["org"], "meta-llama")

    def test_without_an_expected_org_the_best_non_reasoning_run_wins(self):
        entries = [
            {"org": "a", "reasoning": True, "rank": 95.0},
            {"org": "b", "reasoning": False, "rank": 70.0},
            {"org": "c", "reasoning": False, "rank": 80.0},
        ]
        self.assertEqual(catalog.choose_entry(entries, set())["org"], "c")

    def test_expected_orgs_include_aliases(self):
        self.assertEqual(catalog.expected_orgs("Qwen/Qwen3-4B"), {"qwen", "alibaba"})
        self.assertEqual(catalog.expected_orgs("meta-llama/Llama-3.2-3B-Instruct"), {"meta-llama", "meta"})
        self.assertEqual(catalog.expected_orgs(None), set())


class ReasoningRunTests(unittest.TestCase):
    def test_non_reasoning_runs_are_not_reasoning_runs(self):
        self.assertFalse(catalog.is_reasoning_variant("Qwen3 1.7B (Non-reasoning)"))
        self.assertFalse(catalog.is_reasoning_variant("alibaba/qwen3-1.7b-instruct"))
        self.assertFalse(catalog.is_reasoning_variant("Some Model (non reasoning)"))

    def test_reasoning_runs_are_flagged(self):
        self.assertTrue(catalog.is_reasoning_variant("Qwen3 1.7B (Reasoning)"))
        self.assertTrue(catalog.is_reasoning_variant("alibaba/qwen3-1.7b-instruct-reasoning"))
        self.assertTrue(catalog.is_reasoning_variant("Qwen3-4B-Thinking-2507"))

    def test_non_reasoning_run_beats_a_higher_scoring_reasoning_run(self):
        names = {"plain": "Qwen3 1.7B (Non-reasoning)", "thinking": "Qwen3 1.7B (Reasoning)"}
        entries = [
            {"org": "alibaba", "reasoning": catalog.is_reasoning_variant(names["plain"]), "rank": 0.283},
            {"org": "alibaba", "reasoning": catalog.is_reasoning_variant(names["thinking"]), "rank": 0.356},
        ]
        self.assertEqual(catalog.choose_entry(entries, {"alibaba"})["rank"], 0.283)


def _record(day: str, value: str) -> dict:
    moment = datetime.datetime.fromisoformat(day + "T09:00:00+00:00")
    return {"retrieved_timestamp": str(moment.timestamp()), "value": value}


class SnapshotTests(unittest.TestCase):
    def test_snapshot_is_the_newest_on_or_before_the_cutoff(self):
        records = [_record("2026-10-28", "after"), _record("2026-10-27", "pinned"), _record("2026-04-11", "old")]
        self.assertEqual(catalog.pick_snapshot(records, "2026-10-27")["value"], "pinned")
        self.assertEqual(catalog.pick_snapshot(records, "2026-10-30")["value"], "after")

    def test_without_a_cutoff_the_newest_snapshot_wins(self):
        records = [_record("2026-04-11", "old"), _record("2026-10-28", "newest"), _record("2026-10-27", "middle")]
        self.assertEqual(catalog.pick_snapshot(records, None)["value"], "newest")

    def test_no_snapshot_before_the_cutoff_means_no_record(self):
        self.assertIsNone(catalog.pick_snapshot([_record("2026-10-28", "after")], "2026-10-27"))
        self.assertIsNone(catalog.pick_snapshot([], None))

    def test_artificial_analysis_is_pinned_to_the_last_day_it_published_its_indexes(self):
        self.assertEqual(catalog.SNAPSHOT_DATES, {"artificial-analysis-llms": "2026-10-27"})


class _Response:
    headers = {}

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False

    def read(self):
        return b"ok"


class FetcherTests(unittest.TestCase):
    def _fetcher(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        return catalog.Fetcher(Path(directory.name), None)

    def test_retries_rate_limits_and_dropped_connections(self):
        failures = [
            urllib.error.HTTPError("u", 429, "Too Many Requests", {"Retry-After": "7"}, None),
            socket.timeout("timed out"),
            http.client.IncompleteRead(b""),
        ]

        def urlopen(request, timeout):
            if failures:
                raise failures.pop(0)
            return _Response()

        with mock.patch.object(catalog.urllib.request, "urlopen", urlopen), mock.patch.object(catalog.time, "sleep") as sleep:
            self.assertEqual(self._fetcher().get("https://example.test/a"), b"ok")
        self.assertEqual(sleep.call_args_list[0], mock.call(7))
        self.assertEqual(sleep.call_count, 3)

    def test_not_found_is_not_retried(self):
        def urlopen(request, timeout):
            raise urllib.error.HTTPError("u", 404, "Not Found", {}, None)

        with mock.patch.object(catalog.urllib.request, "urlopen", urlopen), mock.patch.object(catalog.time, "sleep") as sleep:
            with self.assertRaises(urllib.error.HTTPError):
                self._fetcher().get("https://example.test/a")
        sleep.assert_not_called()


class ConfigTests(unittest.TestCase):
    def test_kv_bytes(self):
        self.assertEqual(
            catalog.kv_bytes_per_token({"num_hidden_layers": 36, "num_key_value_heads": 8, "head_dim": 128}),
            147456,
        )
        self.assertEqual(
            catalog.kv_bytes_per_token(
                {"text_config": {"num_hidden_layers": 2, "num_key_value_heads": 1, "hidden_size": 64, "num_attention_heads": 4}}
            ),
            2 * 1 * 16 * 4,
        )

    def test_weight_bytes_from_safetensors(self):
        self.assertEqual(
            catalog.weight_bytes({"U32": 1720451072, "BF16": 123904}, 4),
            int(1720451072 * 0.5625) + 123904 * 2,
        )
        self.assertEqual(catalog.weight_bytes({"U32": 1000, "BF16": 4}, 8), int(1000 * 1.0625) + 8)
        self.assertEqual(catalog.weight_bytes({"BF16": 100, "F32": 1}, 16), 204)

    def test_weight_bytes_for_packed_counts(self):
        # Some repos report packed U32 words instead of parameter counts.
        nemotron = {"U8": 986533632, "U32": 3946134528, "F32": 4416, "BF16": 8859648}
        self.assertEqual(
            catalog.weight_bytes(nemotron, 4, total_params=30),
            3946134528 * 4 + 986533632 + 4416 * 4 + 8859648 * 2,
        )
        self.assertEqual(
            catalog.weight_bytes({"U32": 1720451072, "BF16": 123904}, 4, total_params=1.7),
            int(1720451072 * 0.5625) + 123904 * 2,
        )

    def test_supports_tools(self):
        self.assertTrue(catalog.supports_tools({"chat_template_jinja": "{% if tools %}...{% endif %}"}))
        self.assertTrue(catalog.supports_tools({"tokenizer_config": {"chat_template": "{{ tools }}"}}))
        self.assertFalse(catalog.supports_tools({"tokenizer_config": {"chat_template": "{{ messages }}"}}))
        self.assertFalse(catalog.supports_tools({}))


class ScoreTests(unittest.TestCase):
    AA = "artificial-analysis-llms"
    INDEX = "artificial_analysis.artificial_analysis_intelligence_index"
    GPQA = "artificial_analysis.gpqa"

    def test_each_category_has_exactly_one_test(self):
        tested = [category for tests in catalog.BENCHMARKS.values() for category in tests.values()]
        self.assertEqual(sorted(tested), sorted(catalog.CATEGORY_ORDER))
        self.assertEqual(len(catalog.CATEGORY_ORDER), 7)

    def test_gpqa_scores_math_reasoning(self):
        self.assertEqual(catalog.BENCHMARKS[self.AA][self.GPQA], "math_reasoning")

    def test_mark_is_out_of_100(self):
        self.assertEqual(catalog.mark(self.GPQA, 0.849), 84.9)
        self.assertEqual(catalog.mark("Culturally Agnostic", 0.921), 92.1)
        self.assertEqual(catalog.mark(self.INDEX, 15.6), 15.6)
        self.assertEqual(catalog.mark("livebench/language", 71.338), 71.34)

    def test_every_test_is_scaled_to_100(self):
        scales = catalog.FRACTION_TESTS | catalog.PERCENT_TESTS
        tests = {test for tests in catalog.BENCHMARKS.values() for test in tests}
        self.assertEqual(tests, scales)
        self.assertFalse(catalog.FRACTION_TESTS & catalog.PERCENT_TESTS)

    def test_a_score_is_the_mark_and_does_not_depend_on_other_models(self):
        mapping = {f"{self.AA}:{self.GPQA}": "math_reasoning"}
        alone = catalog.category_scores({f"{self.AA}:{self.GPQA}": {"m": 0.5}}, mapping)
        crowd = catalog.category_scores({f"{self.AA}:{self.GPQA}": {"m": 0.5, "better": 0.9}}, mapping)
        self.assertEqual(alone["m"], {"math_reasoning": 50.0})
        self.assertEqual(crowd["m"], {"math_reasoning": 50.0})
        self.assertEqual(crowd["better"], {"math_reasoning": 90.0})

    def test_a_model_without_the_test_gets_no_score(self):
        out = catalog.category_scores(
            {f"{self.AA}:{self.GPQA}": {"m": 0.5}, f"{self.AA}:{self.INDEX}": {"other": 9.0}},
            {f"{self.AA}:{self.GPQA}": "math_reasoning", f"{self.AA}:{self.INDEX}": "general"},
        )
        self.assertEqual(out, {"m": {"math_reasoning": 50.0}, "other": {"general": 9.0}})


if __name__ == "__main__":
    unittest.main()
