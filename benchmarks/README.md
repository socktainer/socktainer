# Runtime benchmarks

The runtime benchmark compares Docker-compatible engines on one Apple Silicon
Mac. It does not support performance claims between different machines.

The repository uses a small purpose-built harness. It needs only tools that are
already present on a normal macOS development system: Bash, Python 3, Docker
CLI, `jq`, ApacheBench, and macOS process tools. The harness uses direct Unix
socket requests for API timing. It does not copy Dory's removed GPL benchmark
code or require a general benchmark framework.

## Measurement policy

- Use pinned native `linux/arm64` Alpine and NGINX image digests.
- Reset the declared product state before each sample. The output records the
  exact reset command and policy. A benchmark-scoped reset can retain an image
  cache. The harness marks cold capability results as non-comparative when
  selected products declare different image-cache policies.
- Pull both fixtures and run one unmeasured Alpine `uname -m` container before
  warm cases. The sample fails if it does not report native arm64 execution.
- Send 50 unmeasured API pings before the 500-request API sample.
- Send 1,000 unmeasured NGINX requests before each measured load.
- Use a seeded randomized Williams design. A complete five-product design uses
  10 samples. It balances position and first-order carryover.
- Retain every measured sample. Flag Tukey 1.5-IQR outliers, but do not remove
  them. Report median, p25, p75, p95, mean, standard deviation, coefficient of
  variation, and a seeded bootstrap 95% interval for the median.
- Fail a sample when a command, API response, container exit, or HTTP workload
  is incorrect. Do not record failed work as a fast result.
- Remove only containers that have the current benchmark run label. Review all
  external product reset commands before you permit them.

CPU hashing and cached bind read remain as diagnostic measurements from the
existing suite. Their result rows have `optimizationGoal: false`. Do not use
them to select Glass Dock optimization work.

## Commands

Build Glass Dock and its guest artifacts first. Then inspect availability:

```sh
make release guest-image vmm
make benchmark-discover
make benchmark-preflight
make benchmark
```

Use a short selective run during harness development:

```sh
scripts/benchmark-runtime.sh \
  --suites startup,lifecycle \
  --samples 4 \
  --seed 73 \
  --output ./runtime-benchmark-local.json
```

The sample count must complete the generated design. One product needs any
positive count. Four products need a multiple of 4. Five products need a
multiple of 10.

For external products, copy [`products.example.sh`](products.example.sh) to a
local file. Check every socket, resource value, storage path, and reset command.
Run a dry run, and then explicitly permit the reviewed resets:

```sh
scripts/benchmark-runtime.sh \
  --config /path/to/products.local.sh \
  --products glassdock,dory,orbstack \
  --samples 6 \
  --seed 73 \
  --allow-unmatched-resources \
  --dry-run

scripts/benchmark-runtime.sh \
  --config /path/to/products.local.sh \
  --products glassdock,dory,orbstack \
  --samples 6 \
  --seed 73 \
  --allow-external-reset \
  --allow-unmatched-resources \
  --output ./runtime-benchmark-comparison.json
```

The harness rejects different declared CPU or memory limits by default. Match
them when each product supports the same limits. Use
`--allow-unmatched-resources` only when a product minimum prevents a match. The
output records this exception and each declared allocation. Treat footprint,
storage, and CPU-sensitive results from such a run as diagnostic results.

Docker Desktop stable and Docker VMM use the same app and socket. Docker does
not publish a command that selects these macOS VMM modes. Select one mode in
Docker Desktop **Settings > General**, run a complete campaign with the matching
declared product, select the other mode, and repeat the same seed and settings.
Treat the two campaigns as separate cohorts. Do not describe them as one
position-balanced five-product run.

## External tool lifecycle

The harness stops benchmark processes and removes only containers labeled with
the current run ID. It does not uninstall Docker Desktop, Dory, or OrbStack
during a run. This keeps benchmark cleanup separate from application and user
data cleanup.

Use the lifecycle helper when you want to install or remove external benchmark
applications between campaigns. It prints a dry-run plan by default:

```sh
scripts/benchmark-tools.sh --action install --products dory,orbstack
scripts/benchmark-tools.sh --action uninstall --products dory,orbstack --apply
```

The helper uses Homebrew casks and does not remove application data. It refuses
to remove Docker Desktop when it finds an EasyLink container in any Docker
context. Keep Docker Desktop installed while EasyLink uses it. Do not pass
`--apply` until you have reviewed the printed commands.

## Suites

| Suite | Measurements |
|---|---|
| `startup` | Socket ready, fresh direct API ping, common capability ready |
| `lifecycle` | Create, start, completed/live wait, remove, run, exec, and repeated lifecycle throughput |
| `nginx` | NGINX readiness, requests per second, and failure count |
| `bind` | Bind write with `fsync` |
| `resources` | Cold, four-container, post-cache, and post-reclaim physical footprint |
| `storage` | Post-reset storage growth, plus diagnostic absolute allocated and logical storage |
| `diagnostics` | 1 GiB SHA-256 and cached bind read; not optimization goals |

## Results and cleanup

The requested JSON file contains the complete manifest, machine data, source
and binary hashes, product configuration, schedule, raw measurements, resource
snapshots, storage snapshots, and statistical summaries. The adjacent
`runtime-benchmark-runs/<run-id>/` directory retains the raw NDJSON files and a
terminal status record. An interrupted run keeps partial raw files and records
the active product and metric.

Do not commit result files. The repository ignores the standard result names.
