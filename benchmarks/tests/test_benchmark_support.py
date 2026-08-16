import json
import subprocess
import sys
import tempfile
import unittest
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from benchmark_support import (  # noqa: E402
    balanced_sequences,
    schedule,
    summarize_rows,
    summarize_values,
    tukey_outlier_indices,
    validate_image_inspect_payload,
)


class ScheduleTests(unittest.TestCase):
    def test_five_products_balance_position_and_carryover(self):
        products = ["glassdock", "dory", "docker-stable", "docker-vmm", "orbstack"]
        sequences = balanced_sequences(products, seed=73)

        self.assertEqual(len(sequences), 10)
        for product in products:
            positions = Counter(sequence.index(product) for sequence in sequences)
            self.assertEqual(positions, Counter({index: 2 for index in range(5)}))

        transitions = Counter(
            (left, right)
            for sequence in sequences
            for left, right in zip(sequence, sequence[1:])
        )
        self.assertEqual(set(transitions.values()), {2})

    def test_even_design_needs_one_sequence_per_product(self):
        sequences = balanced_sequences(["a", "b", "c", "d"], seed=9)
        self.assertEqual(len(sequences), 4)

    def test_schedule_rejects_an_incomplete_design(self):
        with self.assertRaisesRegex(ValueError, "divisible by 10"):
            schedule(["a", "b", "c", "d", "e"], samples=5, seed=1)

    def test_schedule_is_repeatable(self):
        first = schedule(["a", "b", "c"], samples=6, seed=2026)
        second = schedule(["a", "b", "c"], samples=6, seed=2026)
        self.assertEqual(first, second)


class StatisticsTests(unittest.TestCase):
    def test_outliers_are_flagged_and_retained(self):
        values = [10.0, 10.0, 11.0, 11.0, 100.0]
        summary = summarize_values(values, seed=5, resamples=200)
        self.assertEqual(summary["count"], 5)
        self.assertEqual(tukey_outlier_indices(values), [4])
        self.assertEqual(summary["max"], 100.0)

    def test_group_summary_records_sample_numbers_and_goal(self):
        rows = [
            {
                "product": "a",
                "sample": index + 1,
                "position": 1,
                "metric": "diagnostic",
                "value": value,
                "unit": "ms",
                "optimizationGoal": False,
            }
            for index, value in enumerate([1.0, 1.0, 1.0, 1.0, 10.0])
        ]
        summary = summarize_rows(rows, seed=3, resamples=200)[0]
        self.assertEqual(summary["outlierSamples"], [5])
        self.assertFalse(summary["optimizationGoal"])

    def test_cli_emits_ndjson_schedule(self):
        result = subprocess.run(
            [
                sys.executable,
                str(ROOT / "benchmark_support.py"),
                "schedule",
                "--products",
                "a,b,c",
                "--samples",
                "6",
                "--seed",
                "4",
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        rows = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(len(rows), 6)


class ImageInspectTests(unittest.TestCase):
    IMAGE = "docker.io/library/alpine@sha256:abc123"

    def test_accepts_portable_identity_without_optional_rootfs(self):
        validate_image_inspect_payload(
            [{"RepoDigests": ["docker.io/library/alpine@sha256:abc123"]}],
            self.IMAGE,
        )

    def test_accepts_nonempty_rootfs_when_runtime_supplies_it(self):
        validate_image_inspect_payload(
            [
                {
                    "Architecture": "arm64",
                    "RepoDigests": ["docker.io/library/alpine@sha256:abc123"],
                    "RootFS": {"Layers": ["sha256:layer"]},
                }
            ],
            self.IMAGE,
        )

    def test_accepts_empty_optional_rootfs_from_partial_apis(self):
        validate_image_inspect_payload(
            [
                {
                    "RepoDigests": ["docker.io/library/alpine@sha256:abc123"],
                    "RootFS": {"Layers": []},
                }
            ],
            self.IMAGE,
        )

    def test_rejects_wrong_digest_or_architecture(self):
        with self.assertRaisesRegex(ValueError, "digest identity"):
            validate_image_inspect_payload(
                [{"RepoDigests": ["docker.io/library/alpine@sha256:different"]}],
                self.IMAGE,
            )
        with self.assertRaisesRegex(ValueError, "not arm64"):
            validate_image_inspect_payload(
                [
                    {
                        "Architecture": "amd64",
                        "RepoDigests": ["docker.io/library/alpine@sha256:abc123"],
                    }
                ],
                self.IMAGE,
            )


if __name__ == "__main__":
    unittest.main()
