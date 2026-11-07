import ast
from pathlib import Path
import unittest


def load_function(name="apply_mlx_memory_limits"):
    source = Path(__file__).resolve().parents[2] / "PythonDistribution/Overlay/nativ_server.py"
    node = next(node for node in ast.parse(source.read_text()).body
                if isinstance(node, ast.FunctionDef) and node.name == name)
    namespace = {}
    exec(compile(ast.Module(body=[node], type_ignores=[]), str(source), "exec"), namespace)
    return namespace[name]


class FakeMX:
    def __init__(self):
        self.calls = []

    def set_memory_limit(self, value):
        self.calls.append(("memory", value))

    def set_cache_limit(self, value):
        self.calls.append(("cache", value))


class WorkerMemoryLimitTests(unittest.TestCase):
    def setUp(self):
        self.apply = load_function()
        self.mx = FakeMX()

    def test_no_environment_changes_nothing(self):
        self.assertEqual(self.apply({}, self.mx), {})
        self.assertEqual(self.mx.calls, [])

    def test_both_limits_are_applied_as_ints(self):
        applied = self.apply(
            {"NATIV_MLX_MEMORY_LIMIT_BYTES": "4000000000", "NATIV_MLX_CACHE_LIMIT_BYTES": "268435456"}, self.mx)
        self.assertEqual(applied, {"memory": 4000000000, "cache": 268435456})
        self.assertEqual(self.mx.calls, [("memory", 4000000000), ("cache", 268435456)])

    def test_invalid_or_non_positive_values_are_ignored(self):
        applied = self.apply(
            {"NATIV_MLX_MEMORY_LIMIT_BYTES": "lots", "NATIV_MLX_CACHE_LIMIT_BYTES": "0"}, self.mx)
        self.assertEqual(applied, {})
        self.assertEqual(self.mx.calls, [])


class ParentWatchdogTests(unittest.TestCase):
    def setUp(self):
        self.should_exit = load_function("worker_parent_has_exited")

    def test_no_parent_pid_never_exits(self):
        self.assertFalse(self.should_exit({}, kill=lambda pid, sig: None))
        self.assertFalse(self.should_exit({"NATIV_PARENT_PID": "nope"}, kill=lambda pid, sig: None))

    def test_live_parent_keeps_running(self):
        self.assertFalse(self.should_exit({"NATIV_PARENT_PID": "123"}, kill=lambda pid, sig: None))

    def test_dead_parent_exits(self):
        def kill(pid, sig):
            raise ProcessLookupError
        self.assertTrue(self.should_exit({"NATIV_PARENT_PID": "123"}, kill=kill))


if __name__ == "__main__":
    unittest.main()
