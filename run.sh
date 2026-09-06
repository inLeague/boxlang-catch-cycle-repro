#!/usr/bin/env bash
#
# Reproduce the BoxLang catch-clause classification spin caused by a CYCLIC
# exception cause chain.
#
# Usage:
#   ./run.sh [BOXLANGS_JAR]     # pass the boxlang runtime jar explicitly, or
#                               # let discovery find it under ~/.CommandBox
#
# The script anchors to its own directory, so it can be invoked from anywhere:
#   /path/to/repo/run.sh [BOXLANGS_JAR]
# A caller-supplied relative JAR path is resolved against the caller's cwd.
#
# Runs (all three must hold for exit 0):
#   control.bxs      linear cause chain  -> exit 0, prints "caught any:
#                                            LinearException" + SCRIPT-COMPLETE
#   repro.bxs        cyclic java chain   -> HANG; main thread in
#                                            ExceptionUtil.exceptionIsOfType
#   repro-native.bxs cyclic native chain -> HANG; same classifier signature
#
# Evidence lands in evidence/ (cleared at the start of every run):
#   control.out            control stdout+stderr
#   repro.out              repro (java cycle) stdout+stderr (SIGQUIT dump inside)
#   repro.jstack           jstack of the hung repro JVM (best effort)
#   repro-native.out       repro-native stdout+stderr (SIGQUIT dump inside)
#   repro-native.jstack    jstack of the hung native JVM (best effort)
#   run-transcript.txt     selected JAR, tool versions, per-check exit statuses
#
# Exit status: 0 only if the control passed AND each repro's captured dump shows
# the classifier frame. A bare timeout (124/137) is NOT sufficient proof — the
# dump must contain ExceptionUtil.exceptionIsOfType in a RUNNABLE main thread.

set -u

# --- Anchor to this script's directory --------------------------------------
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR" || exit 1

mkdir -p evidence classes

# Clear stale diagnostics from any previous run so a missing capture cannot be
# masked by an old file.
rm -f evidence/control.out \
      evidence/repro.out evidence/repro.jstack \
      evidence/repro-native.out evidence/repro-native.jstack

TRANSCRIPT="evidence/run-transcript.txt"
: > "$TRANSCRIPT"
log() {
    echo "$@" | tee -a "$TRANSCRIPT"
}

# --- Locate the BoxLang runtime jar -----------------------------------------
BXJAR=""
if [ "$#" -ge 1 ] && [ -n "$1" ]; then
    # Resolve relative to the CALLER's cwd (we cd'd above; OLDPWD is the caller's).
    case "$1" in
        /*) BXJAR="$1" ;;
        *)  BXJAR="$(cd "$OLDPWD" 2>/dev/null && pwd)/$1" ;;
    esac
elif [ -n "${BOXLANGS_JAR:-}" ]; then
    BXJAR="$BOXLANGS_JAR"
else
    # Discovery: newest boxlang release jar under the CURRENT user's CommandBox.
    # Only runtime jars (exclude *-sources.jar / *-javadoc.jar); compare the
    # version-bearing filename, not the full path, so the highest version wins
    # regardless of which directory tree it lives in.
    best_ver=""
    best_path=""
    while IFS= read -r cand; do
        name=$(basename "$cand")
        case "$name" in
            *-sources.jar|*-javadoc.jar) continue ;;
        esac
        ver=$(echo "$name" | sed -n 's/^boxlang-\([0-9][0-9.]*\)\.jar$/\1/p')
        [ -z "$ver" ] && continue
        if [ -z "$best_ver" ] || [ "$(printf '%s\n%s\n' "$ver" "$best_ver" | sort -V | tail -1)" = "$ver" ]; then
            best_ver="$ver"
            best_path="$cand"
        fi
    done < <(find "$HOME/.CommandBox" -type f -iname "boxlang-*.jar" 2>/dev/null)
    BXJAR="$best_path"
fi
if [ -z "$BXJAR" ] || [ ! -f "$BXJAR" ]; then
    echo "ERROR: no BoxLang runtime jar found. Pass one explicitly:" >&2
    echo "  ./run.sh /path/to/boxlang-1.17.x.jar" >&2
    echo "or install the CommandBox module:" >&2
    echo "  box install commandbox-boxlang" >&2
    echo "or set BOXLANGS_JAR=/path/to/boxlang-1.17.x.jar" >&2
    exit 1
fi
log "Using BoxLang runtime: $BXJAR"
log "Java: $(java -version 2>&1 | head -1)"
log "javac: $(javac -version 2>&1 | head -1)"
log "Run started: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# --- Compile Java helpers ----------------------------------------------------
log ""
log "=== Compiling Java helper classes ==="
if ! javac -d classes java-src/CyclicException.java java-src/LinearException.java; then
    echo "ERROR: javac failed (a JDK is required)" >&2
    exit 1
fi
log "javac OK"

CP="classes:$BXJAR"

# Run one BoxLang script via the runtime. Usage: run_bxs <script> <timeout_s>
# --kill-after: if the JVM ignores SIGTERM, timeout escalates to SIGKILL and
# returns 137 (distinct from the plain-timeout 124). Both are accepted below;
# the decisive check is the captured classifier frame, not the exit code alone.
run_bxs() {
    timeout --kill-after=5 "$2" java -cp "$CP" ortus.boxlang.runtime.BoxRunner "$1"
}

# --- Run one repro and validate the classifier signature --------------------
# $1 = script name, $2 = label
# Returns 0 only if a main-thread dump shows the classifier spin.
run_hang_check() {
    local script="$1"
    local label="$2"
    local out="evidence/${script%.bxs}.out"
    local jstk="evidence/${script%.bxs}.jstack"
    local ok=0

    log ""
    log "=== $label ($script): expect HANG in ExceptionUtil.exceptionIsOfType ==="
    run_bxs "$script" 20 > "$out" 2>&1 &
    local runner_pid=$!
    sleep 6

    # Select the JAVA child of the timeout runner — NOT the timeout wrapper or
    # the bash subshell. Process tree: bash(run.sh) -> timeout -> java.
    local java_pid=""
    local candidate
    for candidate in $(pgrep -f "ortus.boxlang.runtime.BoxRunner $script" 2>/dev/null); do
        if [ "$(ps -o comm= -p "$candidate" 2>/dev/null)" = "java" ] \
           && kill -0 "$candidate" 2>/dev/null; then
            local p="$candidate"
            while [ "$p" -gt 1 ] 2>/dev/null; do
                [ "$p" = "$runner_pid" ] && { java_pid="$candidate"; break; }
                p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
            done
            [ -n "$java_pid" ] && break
        fi
    done

    if [ -n "$java_pid" ]; then
        log "  hung java pid: $java_pid — SIGQUIT + jstack"
        kill -QUIT "$java_pid" 2>/dev/null  # thread dump to $out
        sleep 1
        # Best-effort jstack; bounded at 5s. Attach can fail on a hot-spinning
        # JVM — the SIGQUIT dump in $out is the authoritative evidence.
        timeout 5 jstack "$java_pid" > "$jstk" 2>&1
        sleep 1
    else
        log "  WARN: no java child of runner found at 6s"
    fi

    wait "$runner_pid"
    local rc=$?
    log "  $script exit: $rc (124 = timeout, 137 = timeout+SIGKILL; both expected for a hang)"

    # A bare timeout is NOT sufficient. The captured main-thread dump must show
    # the classifier frame. Check both possible evidence sources.
    if grep -q "java.lang.Thread.State: RUNNABLE" "$jstk" 2>/dev/null \
       && grep -q "ExceptionUtil.exceptionIsOfType" "$jstk" 2>/dev/null; then
        ok=1
    elif grep -q "ExceptionUtil.exceptionIsOfType" "$out" 2>/dev/null; then
        ok=1
    fi

    if grep -q "SCRIPT-COMPLETE" "$out" 2>/dev/null; then
        log "  FAIL: $script printed SCRIPT-COMPLETE; it did NOT hang"
        return 1
    fi
    if [ "$rc" -ne 124 ] && [ "$rc" -ne 137 ]; then
        log "  FAIL: $script exited $rc; expected 124 or 137 (hang)"
        return 1
    fi
    if [ "$ok" -ne 1 ]; then
        log "  FAIL: no ExceptionUtil.exceptionIsOfType frame in captured dump"
        log "        (exit was $rc, but a hang elsewhere is not a reproduction)"
        return 1
    fi
    log "  OK: $script hung in ExceptionUtil.exceptionIsOfType"
    return 0
}

# --- Control: linear chain must exit 0 with the expected markers ------------
log ""
log "=== CONTROL: linear cause chain (expect clean exit) ==="
run_bxs control.bxs 20 > evidence/control.out 2>&1
ctl_rc=$?
log "  control exit: $ctl_rc"
if [ "$ctl_rc" -ne 0 ] && [ "$ctl_rc" -ne 124 ] && [ "$ctl_rc" -ne 137 ]; then
    log "  FAIL: control exited $ctl_rc, expected 0"
    exit 1
fi
if [ "$ctl_rc" -ne 0 ]; then
    log "  FAIL: control did not exit 0 ($ctl_rc) — it hung or was killed"
    exit 1
fi
if ! grep -q "caught any: LinearException" evidence/control.out; then
    log "  FAIL: control did not catch LinearException"
    exit 1
fi
if ! grep -q "SCRIPT-COMPLETE" evidence/control.out; then
    log "  FAIL: control did not print SCRIPT-COMPLETE"
    exit 1
fi
log "  OK: control exited 0, caught LinearException, printed SCRIPT-COMPLETE"

# --- Repro checks ------------------------------------------------------------
status=0
run_hang_check repro.bxs "REPRO (java cyclic chain)" || status=1
run_hang_check repro-native.bxs "REPRO-NATIVE (native cyclic chain)" || status=1

log ""
log "Run finished: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [ "$status" -eq 0 ]; then
    log "=== ALL CHECKS PASSED ==="
else
    log "=== ONE OR MORE CHECKS FAILED ==="
fi
exit "$status"
