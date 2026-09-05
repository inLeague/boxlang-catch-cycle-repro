#!/usr/bin/env bash
# Reproduce the BoxLang catch-clause classification spin caused by a CYCLIC
# exception cause chain.
#
#   ./run.sh              # run control + repro, capture evidence, clean up
#
# Outputs:
#   evidence/control.out  control (linear chain): prints DONE-ANY, exit 0
#   evidence/repro.out    repro (cyclic chain):   HANGS, killed by timeout (rc=124)
#   evidence/repro.jstack thread dump of the hung JVM showing the spin signature
#   evidence/repro.top    top snapshot showing ~100% CPU
set -u
cd "$(dirname "$0")"
mkdir -p evidence classes

BXJAR=$(find /home/hermes/.CommandBox -iname "boxlang-*.jar" -path "*boxlang-1.17*" 2>/dev/null | head -1)
if [ -z "$BXJAR" ]; then
    echo "ERROR: no boxlang-1.17 jar found under /home/hermes/.CommandBox"
    exit 1
fi
echo "Using BoxLang runtime: $BXJAR"

echo ""
echo "=== Compiling Java helper classes ==="
javac -d classes java-src/CyclicException.java java-src/LinearException.java || { echo "javac failed"; exit 1; }

echo ""
echo "=== CONTROL: linear cause chain (expect clean exit) ==="
timeout 30 java -cp "classes:$BXJAR" ortus.boxlang.runtime.BoxRunner control.bxs > evidence/control.out 2>&1
echo "control exit code: $?"
cat evidence/control.out

echo ""
echo "=== REPRO: cyclic cause chain (expect HANG, killed by 30s timeout) ==="
timeout 30 java -cp "classes:$BXJAR" ortus.boxlang.runtime.BoxRunner repro.bxs > evidence/repro.out 2>&1 &
BGPID=$!

# wait for the java child to appear and spin
sleep 8
JPID=$(pgrep -f "java.*BoxRunner repro.bxs" | head -1)
if [ -n "$JPID" ]; then
    echo "repro java pid: $JPID — capturing thread dump + top"
    # Retry the attach a few times: the JVM may reject the handshake while
    # still starting up. 3 tries x 2s. (Fallback: the SIGTERM dump in
    # repro.out below also carries the full spin signature.)
    for attempt in 1 2 3; do
        jstack "$JPID" > evidence/repro.jstack 2>/dev/null && break
        sleep 2
    done
    top -b -n1 -p "$JPID" > evidence/repro.top 2>&1 || true
    ps -o pid,etime,pcpu,rss,args -p "$JPID" >> evidence/repro.top 2>&1
fi

wait $BGPID
echo "repro exit code: $?  (124 = killed by timeout while still spinning = REPRODUCED)"
tail -3 evidence/repro.out
echo ""
echo "=== done. Evidence in evidence/ ==="
