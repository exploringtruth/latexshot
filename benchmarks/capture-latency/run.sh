#!/bin/bash
set -euo pipefail

if [[ $# -lt 5 || $# -gt 7 ]]; then
    echo "Usage: $0 REPOSITORY PYTHON MODEL_DIR WARM_SAMPLE_COUNT RESULT_JSON [REVISION] [baseline|prewarm]" >&2
    exit 2
fi
repository="$1"
runtime="$2"
model="$3"
sample_count="$4"
output="$5"
revision=${6:-HEAD}
experiment=${7:-baseline}
harness=$(cd "$(dirname "$0")" && pwd)

if [[ "$runtime" != /* || ! -x "$runtime" || "$model" != /* || ! -f "$model/inference.pdiparams" ]]; then
    echo "Pass absolute paths to the executable development Python and the prepared model directory." >&2
    exit 2
fi
if [[ ! "$sample_count" =~ ^[1-9][0-9]*$ ]]; then
    echo "Pass a positive integer warm sample count." >&2
    exit 2
fi
if [[ "$output" != /* || -e "$output" || ! -d "$(dirname "$output")" ]]; then
    echo "Pass an absolute path to a new JSON file in an existing directory." >&2
    exit 2
fi

case "$experiment" in
    baseline) test_source="$harness/LatencyBenchmark.swift" ;;
    prewarm)
        if [[ "$sample_count" != 1 ]]; then
            echo "The prewarm experiment runs one capture per startup scenario. Pass a sample count of 1." >&2
            exit 2
        fi
        test_source="$harness/prewarm/LatencyBenchmark.swift"
        ;;
    *)
        echo "Choose baseline or prewarm." >&2
        exit 2
        ;;
esac

commit=$(git -C "$repository" rev-parse --verify "$revision^{commit}")
scratch=$(mktemp -d "${TMPDIR:-/tmp}/latexshot-capture-latency.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
checkout="$scratch/checkout"
mkdir "$checkout"
fixture=benchmarks/fixtures/roots-01.png
git -C "$repository" archive "$commit" -- Package.swift Package.resolved Sources Tests "$fixture" |
    tar -xf - -C "$checkout"
cp "$test_source" "$checkout/Tests/LaTeXShotAppTests/LatencyBenchmark.swift"
xcrun swiftc -swift-version 6 -parse-as-library -o "$scratch/Fixture" "$harness/Fixture.swift"

printf 'Measuring commit %s\n' "$commit"
cd "$checkout"
LATEXSHOT_RECOGNITION_PYTHON="$runtime" \
LATEXSHOT_MODEL_DIRECTORY="$model" \
LATEXSHOT_LATENCY_FIXTURE="$scratch/Fixture" \
LATEXSHOT_LATENCY_IMAGE="$checkout/$fixture" \
LATEXSHOT_LATENCY_JSON="$scratch/result.json" \
LATEXSHOT_LATENCY_SAMPLES="$sample_count" \
swift test --configuration release --filter LatencyBenchmark

test -s "$scratch/result.json"
(set -o noclobber; cat "$scratch/result.json" > "$output")
