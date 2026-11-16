# Shared helpers for the tests. Sourced, not run.
# check <description> <expected exit code> <grep -E pattern for stdout+stderr> -- <command...>
# finish: prints the counts, exits 1 if any case failed.
# need_iso: stops (exit 2) unless MULTIPROX_TEST_ISO names a file.

test_passed=0
test_failed=0

check() {
  local desc="$1" want="$2" pattern="$3" out rc
  shift 3
  [ "${1:-}" = "--" ] && shift
  set +e
  out=$("$@" 2>&1)
  rc=$?
  set -e
  if [ "$rc" = "$want" ] && grep -qE -- "$pattern" <<<"$out"; then
    echo "ok    $desc"
    test_passed=$((test_passed + 1))
  else
    echo "FAIL  $desc (exit $rc, wanted $want; output must match: $pattern)"
    tail -n 5 <<<"$out" | sed 's/^/        | /'
    test_failed=$((test_failed + 1))
  fi
}

finish() {
  echo "$test_passed passed, $test_failed failed"
  [ "$test_failed" = 0 ]
}

need_iso() {
  if [ -z "${MULTIPROX_TEST_ISO:-}" ] || [ ! -f "$MULTIPROX_TEST_ISO" ]; then
    echo "$(basename "$0"): set MULTIPROX_TEST_ISO to the stock ISO's path" >&2
    exit 2
  fi
}
