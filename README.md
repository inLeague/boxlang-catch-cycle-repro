# BoxLang Catch-Clause Classification Spin — Pathological Exception Cause Chain

Minimal reproduction for an Ortus bug report.

## The suspected runtime flaw

`ortus.boxlang.runtime.types.exceptions.ExceptionUtil.exceptionIsOfType()` walks an
exception's **entire cause chain** when classifying a thrown value against a CFML
`catch` clause:

```java
while ( e != null ) {
    if ( e instanceof BoxLangException ble ) { ... }
    if ( InstanceOf.invoke( context, e, type ) ) return true;
    e = e.getCause();   // ← no visited-set guard
}
```

If the throwable's cause graph is **cyclic** (`A.getCause() == B`,
`B.getCause() == A`), `e.getCause()` never returns `null`, the walk never
terminates, and the thread spins at 100% CPU **before the catch body runs** and
**before the runtime can fall through to a later `catch (any)` clause**.

`ExceptionUtil.buildTagContext()` / `getMergedStackTrace2()` (stack-trace
serialization of the same chain) would loop for the same reason — both functions
appear to lack a visited-set / depth guard on the cause walk.

**Status: VERIFIED as a runtime flaw (2026-09-05).** A synthetic two-node cyclic
cause chain (`A.cause = B`, `B.cause = A`) hangs `exceptionIsOfType` at 100% CPU
— see Result below. This proves the classifier has no visited-set guard and the
flaw is producer-independent: ANY code path that throws a cyclic-cause throwable
into a typed-catch dispatch wedges a worker thread. Production (2026-09-05) shows
this exact spin signature from a Quick/qb ORM query path; the concrete exception
shape from that query is still to be captured, but the runtime defect is confirmed.
The 2026-08-14 incident's Hibernate `wrapWithQueryString` self-cause chain is one
real producer of the same shape.

**Why a typed catch is required.** From `ExceptionUtil.exceptionIsOfType`
bytecode (BoxLang 1.17.0):
- `catch(any)` returns `true` immediately — it never walks the cause chain.
- For a `BoxLangException` it first checks the exception's `.type` string field;
  if that doesn't match the clause it falls through to `InstanceOf.invoke(...)`
  and then `e = e.getCause()`.
- For a plain `Throwable` it goes straight to `InstanceOf.invoke(...)`, and on
  no-match follows `e = e.getCause()` — the unguarded loop.

So a cyclic chain only spins when classification must walk causes, i.e. a typed
(non-any) catch that doesn't match on the first node. Production's
`BaseHandler.aroundHandler` has exactly this shape: five typed catches
(`ValidationException`, `StripeException`, `EntityNotFound|RecordNotFound`,
`TokenInvalidException`, `NoAuthHandlerAuthFailure`) before the `catch(any)`.
Any thrown cyclic-cause value is walked against each typed clause first.

A note on a native-exception variant: we attempted to build a cyclic cause chain
entirely from BoxLang-native `CustomException` instances (via the
`CustomException(String, Throwable)` ctor) but could not construct a true
mutual cycle through interop — object identity did not survive the two-pass
build. The Java-class cycle below is the minimal verified construction; the
mechanism it triggers is in the runtime's classifier, so the class origin of the
cyclic throwable does not matter once the chain is cyclic.

## Result (verified 2026-09-05, local BoxLang 1.17.0)

- `control.bxs` (linear cause chain) → exit 0, prints `caught any` / `DONE-ANY` / `SCRIPT-COMPLETE` in <1s.
- `repro.bxs` (cyclic 2-node cause chain) → **never returns**. Killed by `timeout 30` (rc=124) still at ~100% CPU.
- SIGTERM thread dump (`evidence/repro.out`) of the hung JVM shows the main thread:

```
"main" prio=5 cpu=7977ms elapsed=8.13s  (≈98% of a core)
   java.lang.Thread.State: RUNNABLE
     at ortus.boxlang.runtime.operators.InstanceOf.isAssignableFromIgnoreCase(InstanceOf.java:162)
     at ortus.boxlang.runtime.operators.InstanceOf.invoke(InstanceOf.java:101)
     at ortus.boxlang.runtime.types.exceptions.ExceptionUtil.exceptionIsOfType(ExceptionUtil.java:84)
     at ...Repro$bxs._invoke(repro.bxs:12)   ← the typed catch clause
```

Identical frame signature to the production incidents (2026-08-14, 2026-09-05):
`ExceptionUtil.exceptionIsOfType` → `InstanceOf` cause-chain walk, spinning before
any catch body runs, `exception.log` stays empty, each request wedges a worker.

### Runtime tested

- BoxLang 1.17.0 (local CommandBox module), Temurin JDK 25.
- Production incident ran BoxLang 1.17.2+60 (Runwar 6.1.7, Temurin 25.0.3).

## Reproduce

```
./run.sh
```

Requires a JDK (`javac`/`jstack`) and the CommandBox BoxLang module (the script
finds `boxlang-1.17*.jar` under `~/.CommandBox`). Run `box update
commandbox-boxlang` first if missing. Outputs land in `evidence/`.
