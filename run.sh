#!/usr/bin/env bash
#
# Reproduce the BoxLang catch-clause classification spin caused by a CYCLIC
# exception cause chain.
#
# Usage:
#   ./run.sh [BOXLANGS_JAR]     # pass the boxlang runtime jar explicitly, or
#                               # let discovery find it under ~/.CommandBox
#
# Runs:
#   control.bxs      linear cause chain  -> must exit 0 with DONE-ANY marker
#   repro.bxs        cyclic java chain   -> must HANG; killed by timeout
#   repro-native.bxs cyclic native chain -> must HANG; killed by timeout
#
# Evidence lands in evidence/:
#   control.out          control stdout+stderr
#   repro.out            repro (java cycle) stdout+stderr (SIGQUIT dump inside)
#   repro.jstack         jstack of the hung repro JVM (best effort)
#   repro-native.out     repro-native stdout+stderr (SIGQUIT dump inside)
#   repro-native.jstack  jstack of the hung native JVM (best effort)
#
# Exit status: 0 = control passed AND both repros hung as expected.
#              1 = any check failed. Never exits 0 without validating.

set -u

# --- Locate the BoxLang runtime jar -----------------------------------------
BXJAR=""
if [ "$#" -ge 1 ] && [ -n "$1" ]; then
    BXJAR="$1"
elif [ -n "${BOXLANGS_JAR:-}" ]; then
    BXJAR="$BOXLANGS_JAR"
else
    # Discovery: newest boxlang-1.17* jar under the CURRENT user's CommandBox.
    # Prefer an explicit path/version; this is a deterministic fallback only.
    CANDIDATES=$(find "$HOME/.CommandBox" -iname "boxlang-1.17*.jar" 2>/dev/null | sort -V)
    BXJAR=$(echo "$CANDIDATES" | tail -n 1)
fi
if [ -z "$BXJAR" ] || [ ! -f "$BXJAR" ]; then
    echo "ERROR: no BoxLang runtime jar found. Pass one explicitly:" >&2
    echo "  ./run.sh /path/to/boxlang-1.17.x.jar" >&2
    echo "or install the CommandBox module:" >&2
    echo "  box install commandbox-boxlang" >&2
    echo "or set BOXLANGS_JAR=/path/to/boxlang-1.17.x.jar" >&2
    exit 1
fi
echo "Using BoxLang runtime: $BXJAR"

mkdir -p evidence classes

# --- Compile Java helpers ----------------------------------------------------
echo ""
echo "=== Compiling Java helper classes ==="
if ! javac -d classes java-src/CyclicException.java java-src/LinearException.java; then
    echo "ERROR: javac failed (a JDK is required)" >&2
    exit 1
fi

CP="classes:$BXJAR"

# Run one BoxLang script via the runtime. Usage: run_bxs <script> <timeout_s> [> out 2>&1]
run_bxs() {
    timeout --kill-after=5 "$2" java -cp "$CP" ortus.boxlang.runtime.BoxRunner "$1"
}

# --- Run one repro and validate it hangs ------------------------------------
# $1 = script name, $2 = label
run_hang_check() {
    local script="$1"
    local label="$2"
    local out="evidence/${script%.bxs}.out"
    local jstk="evidence/${script%.bxs}.jstack"
    echo ""
    echo "=== $label ($script): expect HANG ==="
    # --kill-after=5 ensures the JVM is killed even if it ignores SIGTERM.
    # SIGQUIT before the kill produces a thread dump in the JVM's stdout/stderr
    # (HotSpot prints the dump on SIGQUIT, then continues running).
    run_bxs "$script" 20 > "$out" 2>&1 &
    local runner_pid=$!
    sleep 6

    # Select the JAVA child of the timeout runner — NOT the timeout wrapper or
    # the bash subshell. Process tree: bash(run.sh) -> timeout -> java. The
    # backgrounded $! is the bash subshell (or timeout when run directly);
    # find the java process and confirm it is a descendant of this runner.
    local java_pid=""
    local candidate
    for candidate in $(pgrep -f "ortus.boxlang.runtime.BoxRunner $script" 2>/dev/null); do
        # must be a java process (not the timeout/bash wrapper) and a descendant
        if [ "$(ps -o comm= -p "$candidate" 2>/dev/null)" = "java" ] \
           && kill -0 "$candidate" 2>/dev/null; then
            # confirm it descends from runner_pid
            local p="$candidate"
            while [ "$p" -gt 1 ] 2>/dev/null; do
                [ "$p" = "$runner_pid" ] && { java_pid="$candidate"; break; }
                p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
            done
            [ -n "$java_pid" ] && break
        fi
    done
    if [ -n "$java_pid" ]; then
        echo "  hung java pid: $java_pid — SIGQUIT + jstack"
        kill -QUIT "$java_pid" 2>/dev/null  # thread dump to $out
        sleep 1
        # Best-effort jstack; bounded at 5s. Attach can fail on a hot-spinning
        # JVM ("not ready to participate in attach handshake") — that failure
        # is informative, keep it.
        timeout 5 jstack "$java_pid" > "$jstk" 2>&1 || echo "  (jstack attach failed; see $jstk)"
        sleep 1
    else
        echo "  WARN: no java child of runner found at 6s — checking output"
    fi

    wait "$runner_pid"
    local rc=$?
    echo "  $script exit: $rc (124 = timed out while spinning = expected)"

    # Validate: must have been killed by the timeout, and output must show the
    # classifier spin (SIGQUIT dump) OR at least not have completed.
    if [ "$rc" -ne 124 ]; then
        echo "  FAIL: $script exited $rc, expected 124 (hang)" >&2
        return 1
    fi
    if grep -q "SCRIPT-COMPLETE" "$out"; then
        echo "  FAIL: $script completed; it did NOT hang" >&2
        return 1
    fi
    echo "  OK: $script hung as expected"
    return 0
}

# --- Control: linear chain must exit 0 and print the marker ------------------
echo ""
echo "=== CONTROL: linear cause chain (expect clean exit) ==="
timeout 20 java -cp "$CP" ortus.boxlang.runtime.BoxRunner control.bxs > evidence/control.out 2>&1
ctl_rc=$?
if [ "$ctl_rc" -ne 0 ]; then
    echo "  FAIL: control exited $ctl_rc, expected 0" >&2
    exit 1
fi
if ! grep -q "DONE-ANY" evidence/control.out; then
    echo "  FAIL: control did not print DONE-ANY marker" >&2
    echo "  --- control.out ---"; cat evidence/control.out >&2
    exit 1
fi
echo "  OK: control exited 0 with DONE-ANY marker"

# --- Repro checks ------------------------------------------------------------
status=0
run_hang_check repro.bxs "REPRO (java cyclic chain)" || status=1
run_hang_check repro-native.bxs "REPRO-NATIVE (native cyclic chain)" || status=1

echo ""
if [ "$status" -eq 0 ]; then
    echo "=== ALL CHECKS PASSED ==="
else
    echo "=== ONE OR MORE CHECKS FAILED ===" >&2
fi
exit "$status"
