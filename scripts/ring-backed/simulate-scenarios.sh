#!/usr/bin/env bash
set -euo pipefail

run_scenarios() {
    local test_pattern="$1"
    local command=(forge test --match-contract RingBackedScenarioMatrix --match-test "$test_pattern" -vv)
    if [[ "${RAW:-false}" == "true" ]]; then
        "${command[@]}"
    else
        "${command[@]}" 2>&1 | python3 scripts/ring-backed/format-scenarios.py
    fi
}

case "${1:-all}" in
    matrix)
        run_scenarios 'test_Matrix_'
        ;;
    sequence)
        run_scenarios 'test_SequentialPriceDrift'
        ;;
    all)
        run_scenarios 'test_(Matrix_|SequentialPriceDrift)'
        ;;
    *)
        echo "Usage: $0 {all|matrix|sequence}" >&2
        exit 1
        ;;
esac
