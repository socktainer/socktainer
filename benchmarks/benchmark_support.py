#!/usr/bin/env python3

"""Deterministic schedule and statistical helpers for runtime benchmarks."""

from __future__ import annotations

import argparse
import json
import math
import random
import statistics
import sys
from collections import Counter, defaultdict
from pathlib import Path
from typing import Iterable, Sequence


def balanced_sequences(products: Sequence[str], seed: int) -> list[list[str]]:
    """Return a randomized Williams design for the supplied products.

    Even treatment counts need N sequences. Odd treatment counts need the N
    sequences and their reverses to balance first-order carryover.
    """

    if not products:
        raise ValueError("at least one product is required")
    if len(set(products)) != len(products):
        raise ValueError("product names must be unique")
    if len(products) == 1:
        return [[products[0]]]

    rng = random.Random(seed)
    treatments = list(products)
    rng.shuffle(treatments)
    count = len(treatments)

    indices = [0]
    for offset in range(1, count):
        if offset % 2:
            indices.append((offset + 1) // 2)
        else:
            indices.append(count - offset // 2)

    sequences = [
        [treatments[(index + shift) % count] for index in indices]
        for shift in range(count)
    ]
    if count % 2:
        sequences.extend(list(reversed(sequence)) for sequence in sequences.copy())
    rng.shuffle(sequences)
    return sequences


def schedule(products: Sequence[str], samples: int, seed: int) -> list[list[str]]:
    sequences = balanced_sequences(products, seed)
    if samples <= 0:
        raise ValueError("samples must be positive")
    if samples % len(sequences):
        raise ValueError(
            f"samples must be divisible by {len(sequences)} for this "
            "position-and-carryover-balanced design"
        )
    return [sequences[index % len(sequences)] for index in range(samples)]


def percentile(values: Sequence[float], probability: float) -> float:
    if not values:
        raise ValueError("percentile needs at least one value")
    ordered = sorted(values)
    position = (len(ordered) - 1) * probability
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)


def tukey_outlier_indices(values: Sequence[float]) -> list[int]:
    if len(values) < 4:
        return []
    q1 = percentile(values, 0.25)
    q3 = percentile(values, 0.75)
    spread = q3 - q1
    lower = q1 - 1.5 * spread
    upper = q3 + 1.5 * spread
    return [index for index, value in enumerate(values) if value < lower or value > upper]


def bootstrap_median_interval(
    values: Sequence[float], *, seed: int, resamples: int
) -> tuple[float, float]:
    if not values:
        raise ValueError("bootstrap needs at least one value")
    if resamples <= 0:
        raise ValueError("bootstrap resamples must be positive")
    rng = random.Random(seed)
    count = len(values)
    medians = [
        statistics.median(values[rng.randrange(count)] for _ in range(count))
        for _ in range(resamples)
    ]
    return percentile(medians, 0.025), percentile(medians, 0.975)


def summarize_values(
    values: Sequence[float], *, seed: int, resamples: int
) -> dict[str, object]:
    if not values:
        raise ValueError("summary needs at least one value")
    mean = statistics.fmean(values)
    standard_deviation = statistics.stdev(values) if len(values) > 1 else 0.0
    interval = bootstrap_median_interval(values, seed=seed, resamples=resamples)
    return {
        "count": len(values),
        "median": statistics.median(values),
        "medianConfidenceInterval95": {"low": interval[0], "high": interval[1]},
        "mean": mean,
        "standardDeviation": standard_deviation,
        "coefficientOfVariation": standard_deviation / mean if mean else None,
        "p25": percentile(values, 0.25),
        "p75": percentile(values, 0.75),
        "p95": percentile(values, 0.95),
        "min": min(values),
        "max": max(values),
        "outlierSampleIndices": tukey_outlier_indices(values),
    }


def summarize_rows(
    rows: Iterable[dict[str, object]], *, seed: int, resamples: int
) -> list[dict[str, object]]:
    groups: dict[tuple[str, str], list[dict[str, object]]] = defaultdict(list)
    for row in rows:
        groups[str(row["product"]), str(row["metric"])].append(row)

    summaries = []
    for group_index, ((product, metric), group) in enumerate(sorted(groups.items())):
        group.sort(key=lambda row: int(row["sample"]))
        values = [float(row["value"]) for row in group]
        summary = summarize_values(
            values, seed=seed + group_index * 1_000_003, resamples=resamples
        )
        outlier_positions = set(summary.pop("outlierSampleIndices"))
        summary.update(
            {
                "product": product,
                "metric": metric,
                "unit": group[0]["unit"],
                "optimizationGoal": bool(group[0].get("optimizationGoal", True)),
                "outlierSamples": [
                    int(row["sample"])
                    for index, row in enumerate(group)
                    if index in outlier_positions
                ],
                "positionCounts": dict(
                    sorted(Counter(str(row["position"]) for row in group).items())
                ),
                "outlierPolicy": "flag Tukey 1.5 IQR outliers; retain all samples",
            }
        )
        summaries.append(summary)
    return summaries


def read_ndjson(path: Path) -> list[dict[str, object]]:
    with path.open(encoding="utf-8") as source:
        return [json.loads(line) for line in source if line.strip()]


def validate_image_inspect_payload(payload: object, image: str) -> None:
    """Validate the portable image identity fields used by the benchmark."""

    if not isinstance(payload, list) or len(payload) != 1:
        raise ValueError("image inspect must return one response")
    response = payload[0]
    if not isinstance(response, dict):
        raise ValueError("image inspect response must be an object")

    architecture = response.get("Architecture")
    if architecture not in (None, "", "arm64"):
        raise ValueError(f"fixture is not arm64: {image} ({architecture})")

    digest = image.rpartition("@")[2]
    repo_digests = response.get("RepoDigests")
    if not isinstance(repo_digests, list) or not any(
        isinstance(item, str) and item.endswith(f"@{digest}") for item in repo_digests
    ):
        raise ValueError(f"fixture digest identity was not retained: {image}")

def write_schedule(args: argparse.Namespace) -> None:
    products = [item for item in args.products.split(",") if item]
    result = schedule(products, args.samples, args.seed)
    for sample, sequence in enumerate(result, start=1):
        print(
            json.dumps(
                {"sample": sample, "products": sequence},
                separators=(",", ":"),
            )
        )


def write_summary(args: argparse.Namespace) -> None:
    rows = read_ndjson(Path(args.input))
    json.dump(
        summarize_rows(rows, seed=args.seed, resamples=args.resamples),
        sys.stdout,
        separators=(",", ":"),
    )
    print()


def validate_image_inspect(args: argparse.Namespace) -> None:
    validate_image_inspect_payload(json.load(sys.stdin), args.image)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)

    schedule_parser = commands.add_parser("schedule")
    schedule_parser.add_argument("--products", required=True)
    schedule_parser.add_argument("--samples", type=int, required=True)
    schedule_parser.add_argument("--seed", type=int, required=True)
    schedule_parser.set_defaults(handler=write_schedule)

    summary_parser = commands.add_parser("summarize")
    summary_parser.add_argument("--input", required=True)
    summary_parser.add_argument("--seed", type=int, required=True)
    summary_parser.add_argument("--resamples", type=int, default=10_000)
    summary_parser.set_defaults(handler=write_summary)

    image_parser = commands.add_parser("validate-image-inspect")
    image_parser.add_argument("--image", required=True)
    image_parser.set_defaults(handler=validate_image_inspect)
    return parser


def main() -> None:
    args = build_parser().parse_args()
    try:
        args.handler(args)
    except (KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
        raise SystemExit(f"benchmark support: {error}") from error


if __name__ == "__main__":
    main()
