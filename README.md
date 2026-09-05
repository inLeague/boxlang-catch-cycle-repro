# BoxLang Catch-Clause Classification Spin — Cyclic Exception Cause Chain

Minimal reproduction for an Ortus bug report.

## The runtime defect

`ortus.boxlang.runtime.types.exceptions.ExceptionUtil.exceptionIsOfType()` walks
an exception's **entire cause chain** when classifying a thrown value against a
CFML `catch` clause:

```java
while ( e != null ) {
    if ( e instanceof BoxLangException ble ) { ... type string check ... }
    if ( InstanceOf.invoke( context, e, type ) ) return true;
    e = e.getCause();   // ← no visited-set guard, no depth cap
}
```

If the throwable's cause graph is **cyclic** (`A.getCause() == B`,
`B.getCause() == A`), `e.getCause()` never returns `null`, so the walk never
terminates for any catch type that does not match a reachable node, and the
thread spins at 100% CPU **before the matching catch body (if any) runs**.

Precise condition for the hang: **the exception has a cyclic cause chain AND no
node reachable in that chain matches the catch type currently being evaluated.**
(A match on the second or subsequent node returns `true` and terminates the walk
normally; the hang happens only when every reachable node fails the match for
the current clause.)

### Why a typed (non-any) catch is required

From `ExceptionUtil.exceptionIsOfType` bytecode (BoxLang 1.17.0):
- `catch(any)` returns `true` immediately — it never walks the cause chain.
- For a `BoxLangException` it first checks the exception's `.type` string field;
  if that doesn't match the clause it falls through to `InstanceOf.invoke(...)`
  and then `e = e.getCause()`.
- For a plain `Throwable` it goes straight to `InstanceOf.invoke(...)`, and on
  no-match follows `e = e.getCause()` — the unguarded loop.

A cyclic chain therefore only spins when classification must walk causes — i.e.
a typed (non-any) catch whose type does not match any reachable node.
Production's `BaseHandler.aroundHandler` has five typed catches
(`ValidationException`, `StripeException`, `EntityNotFound|RecordNotFound`,
`TokenInvalidException`, `NoAuthHandlerAuthFailure`) before the `catch(any)`, so
every thrown exception is walked against each typed clause.

### Stack-trace serialization

`ExceptionUtil.buildTagContext()` calls `getMergedStackTrace2()` internally; both
walk the cause chain to render a stack trace. The same cyclic chain therefore
also hangs stack-trace serialization (a single unguarded walk, not two
independent loops).

## Result (verified 2026-09-05, BoxLang 1.17.0, Temurin 25)

- `control.bxs` (linear cause chain) → exit 0, prints `DONE-ANY` / `SCRIPT-COMPLETE` in <1s.
- `repro.bxs` (cyclic **Java-class** cause chain) → hangs; killed by `timeout` (rc=124) at ~100% CPU.
- `repro-native.bxs` (cyclic **BoxLang-native** `CustomException` chain) → hangs; killed by `timeout` (rc=124) at ~100% CPU.
- Thread dumps (`evidence/repro.jstack`, `evidence/repro-native.jstack`,
  plus the SIGQUIT dumps inside `evidence/repro.out` / `evidence/repro-native.out`)
  show the main thread in the same classifier spin:

```
"main" prio=5 cpu=~7000ms elapsed=~7s   (≈100% of a core)
   java.lang.Thread.State: RUNNABLE
     at ortus.boxlang.runtime.operators.InstanceOf.isAssignableFromIgnoreCase(InstanceOf.java:165)
     at ortus.boxlang.runtime.operators.InstanceOf.invoke(InstanceOf.java:101)
     at ortus.boxlang.runtime.types.exceptions.ExceptionUtil.exceptionIsOfType(ExceptionUtil.java:84)
     at ...Repro$bxs._invoke(...)        ← the try block whose throw is being classified
```

The two repro shapes (raw Java RuntimeException cycle and BoxLang-native
`CustomException` cycle) produce the identical signature, confirming the defect
is in the runtime classifier, independent of the throwable's origin.

### Capture method (evidence provenance)

The thread dump inside `evidence/repro.out` / `evidence/repro-native.out` is a
HotSpot **SIGQUIT** dump: `run.sh` sends `kill -QUIT` to the hung JVM, HotSpot
prints the dump to the JVM's stdout/stderr and the JVM continues running (it is
then killed by the `timeout --kill-after` SIGTERM/SIGKILL). `evidence/repro.jstack`
and `evidence/repro-native.jstack` are `jstack` captures of the same hung JVMs.

## Production context (attribution)

Two production incidents (2026-08-14, 2026-09-05) exhibited this exact spin
signature in request threads. **This repository establishes that the runtime
defect is real** (a synthetic cyclic chain hangs the classifier). It does **not**
establish the concrete exception cause-graph produced by Quick/qb or Hibernate
in those incidents — the exception identities/cause links from production have
not yet been captured. Those incidents are **consistent with** this defect; the
2026-08-14 case showed a Hibernate `QueryException` whose `wrapWithQueryString`
wraps the exception with itself as cause (a cyclic shape), and the 2026-09-05
case fired from a Quick/qb ORM query path.

## Reproduce

```
./run.sh [BOXLANGS_JAR]
```

The runner discovers a BoxLang runtime jar under `$HOME/.CommandBox` (newest
`boxlang-1.17*.jar`) or accepts an explicit path as `$1` / `$BOXLANGS_JAR`
(use the first boxlang command installed via CommandBox module; if missing,
install it with `box install commandbox-boxlang`).

Requires Linux/GNU utilities (`bash`, `find`, `pgrep`, `ps`, `timeout`, `jstack`,
`javac`), a JDK ≥ 17, and a BoxLang runtime jar. Outputs land in `evidence/`.

The runner validates its own results: the control must exit 0 and print
`DONE-ANY`; each repro must exit 124 (timeout kill) and must NOT print
`SCRIPT-COMPLETE`. Exit status is 0 only if all three checks pass.

`verify-native.bxs` (not run by default) prints the native cycle construction
and a 6-step `getCause()` walk to confirm the `a <-> b` cycle is real; useful
when validating the environment before relying on the native repro.

