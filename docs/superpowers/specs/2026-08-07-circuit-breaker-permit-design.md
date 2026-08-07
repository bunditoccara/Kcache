# Circuit Breaker Permit Design

## Goal

Make the circuit breaker state machine linearizable under concurrency without
holding a lock while backend work is running. Adapt the proven permit and
generation model from `example.txt` to this project's Client and SingleFlight
call paths.

## Scope

- Replace the circuit breaker's independent atomic fields with one mutex and
  plain state fields protected by that mutex.
- Replace the boolean admission result with a generation permit.
- Require every admitted request to report success, report failure, or cancel.
- Preserve the current failure accumulation and timeout behavior.
- Update Group, Client, SingleFlight, documentation, and tests for the new API.
- Protect the client breaker pool and keep breakers alive for in-flight RPCs.

No new dependencies or unrelated cache behavior changes are included.

## Public Interface

`CircuitBreaker` exposes a numeric permit representing the state generation in
which a request was admitted:

```cpp
using Permit = std::uint64_t;

std::optional<Permit> Allow();
void RecordSuccess(Permit permit);
void RecordFailure(Permit permit);
void Cancel(Permit permit);
```

`Allow()` returns `std::nullopt` when the request is rejected. A returned permit
must be resolved exactly once. Reports and cancellations carrying a permit from
an older generation are ignored.

## State And Locking

A single `mutable std::mutex` protects the complete breaker state tuple:

- current circuit state;
- generation;
- closed-state failure count and last failure time;
- open time;
- HalfOpen admitted-call and success counts.

All admission decisions, counter updates, and state transitions occur while
holding this mutex. The mutex is released before the caller performs an RPC or
cache load. State inspection methods also acquire the mutex.

Every transition between Closed, Open, and HalfOpen increments the generation.
This prevents results from requests admitted in an earlier state from mutating
the current state, including Closed -> Open -> HalfOpen ABA cycles.

## State Transitions

### Closed

`Allow()` returns the current generation. A valid failure updates the failure
window and increments the failure count atomically under the mutex. Reaching the
configured threshold records the open time, resets HalfOpen counters, enters
Open, and advances the generation.

A valid success preserves the existing behavior: it resets the accumulated
failure count only when there has been no failure or the failure reset timeout
has elapsed.

### Open

Requests are rejected until the recovery timeout elapses. The first request
after the timeout initializes HalfOpen counters, enters HalfOpen, advances the
generation, reserves the first HalfOpen slot, and receives the new permit. All
of these actions happen in one critical section.

### HalfOpen

`Allow()` reserves and returns a permit only while the admitted-call count is
below `half_open_max_calls`. Rejected requests do not increment the count.

Any valid failure immediately records a new open time, clears HalfOpen
counters, enters Open, and advances the generation.

A valid success increments the success count. Recovery occurs only when the
success threshold has been reached and every currently admitted probe has
succeeded:

```text
half_open_successes >= success_threshold
and
half_open_successes == half_open_calls
```

This gives failures from all probes admitted in the generation a chance to
reopen the circuit. Closing clears failure and HalfOpen counters and advances
the generation.

### Cancellation

Cancellation represents an admitted request that did not produce an
independent backend health result. Closed cancellations do nothing. A valid
HalfOpen cancellation returns its reserved slot by decrementing the admitted
call count. If the remaining probes have all succeeded and meet the success
threshold, cancellation completes the recovery transition.

## SingleFlight Adaptation

`SingleFlightResult` gains one ownership flag:

```cpp
bool should_report_breaker = false;
```

The flag is true only for the request selected to represent one independent
backend outcome. Pioneer success, clean not-found, pioneer failure, and the one
timeout selected by `MarkFailureOnce` own the report. Waiters that reuse a
result and cooldown-rejected requests do not.

`KCacheGroup::Load()` resolves its permit as follows:

- owned error: report failure;
- owned non-error, including clean not-found: report success;
- unowned result: cancel.

This prevents multiple waiters from turning one backend operation into several
HalfOpen successes or failures.

## Client Adaptation

Each Client operation keeps the permit returned by `Allow()` until the RPC
outcome is known. A successful response and `NOT_FOUND` report success;
transport and existing failure responses report failure; an exit before an RPC
is issued cancels the permit.

The breaker pool uses `std::shared_ptr<CircuitBreaker>` and a dedicated mutex.
Lookup, insertion, and erase are protected by that mutex. Each request keeps a
shared pointer for the duration of its RPC, so service discovery cannot destroy
an in-flight request's breaker.

## Verification

Focused tests must demonstrate:

- concurrent recovery admits no more than `half_open_max_calls` permits;
- the Open -> HalfOpen transition request consumes a slot;
- old Closed and HalfOpen permits cannot mutate a later generation;
- a valid HalfOpen failure cannot be overwritten by success;
- the breaker closes only after every admitted probe succeeds;
- cancellation returns an unused HalfOpen slot;
- concurrent failure-window resets do not lose failures;
- SingleFlight waiters and cooldown rejection cancel rather than duplicate a
  breaker result;
- removing a client node cannot destroy a breaker held by an in-flight request.

Existing serial circuit breaker, Group fallback, timeout, and client behavior
tests remain passing.
