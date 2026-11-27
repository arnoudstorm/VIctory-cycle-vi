#!/usr/bin/env bash
# Benchmark setting 1: start from the benchmark save in bench-save/ (same spot every run).
# Usage: bench-saved.sh <name> <exe> [launcher switches] [KEY=VALUE ...]
BENCH_START=saved exec bash "$(dirname "$0")/bench.sh" "$@"
