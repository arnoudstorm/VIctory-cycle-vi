#!/usr/bin/env bash
# Benchmark setting 2: no save, the game's opening (story saves moved aside, kept).
# Usage: bench-opening.sh <name> <exe> [launcher switches] [KEY=VALUE ...]
BENCH_START=opening exec bash "$(dirname "$0")/bench.sh" "$@"
