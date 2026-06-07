# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Gem Does

`robot_lab-ractor` enables CPU-parallel execution in RobotLab via Ruby Ractors. It provides a worker pool for CPU-bound tools and a dependency-aware network scheduler for running robot pipelines across Ractor workers.

## Commands

```bash
bundle exec rake test        # Run full test suite
ruby -Ilib:test test/<file>  # Run a single test file
```

## CRITICAL: Never define `module RobotLab::Ractor`

`lib/robot_lab/ractor.rb` intentionally does **not** open `module RobotLab::Ractor`. Defining that module would shadow Ruby's built-in `Ractor` class for all code inside the `RobotLab` namespace, breaking `Ractor.new`, `Ractor.make_shareable`, etc. throughout the codebase. The version constant lives in `RobotLab::RactorPool::VERSION` to avoid this clash.

## Architecture

**`RactorWorkerPool`** (`ractor_worker_pool.rb`) — Pool of Ractor workers for CPU-bound, Ractor-safe tools. Submit a job from any thread; the result is returned synchronously via a per-job `RactorQueue`.

```ruby
pool = RactorWorkerPool.new(size: 4)      # :auto = Etc.nprocessors
result = pool.submit("MyTool", { arg: "value" })
pool.shutdown
```

Accessed globally via `RobotLab.ractor_pool` / `RobotLab.shutdown_ractor_pool`.

**`RactorNetworkScheduler`** (`ractor_network_scheduler.rb`) — Schedules frozen `RobotSpec` payloads across Ractor workers in dependency order. Entry-point robots (`:none` deps) dispatch immediately; dependent robots dispatch once all named deps complete.

```ruby
scheduler = RactorNetworkScheduler.new(memory: shared_memory)
results = scheduler.run_pipeline([
  { spec: analyst_spec, depends_on: :none },
  { spec: writer_spec,  depends_on: ["analyst"] }
], message: "Analyse this")
scheduler.shutdown
```

**`RactorBoundary`** (`ractor_boundary.rb`) — Utility for crossing Ractor boundaries. `freeze_deep(obj)` recursively freezes Hash/Array structures and calls `Ractor.make_shareable`. Raises `RactorBoundaryError` if the value cannot be made shareable (e.g. a live IO or Proc).

**`RactorMemoryProxy`** (`ractor_memory_proxy.rb`) — Wraps a `Memory` instance via `Ractor::Wrapper` so Ractor workers can read and write shared state. Only `get`, `set`, and `keys` are proxied; closures and subscriptions are not Ractor-safe and must use the thread-side Memory directly.

**Data Carriers** (`ractor_job.rb`) — Three frozen `Data.define` structs:
- `RactorJob` — work item: `id`, `type`, `payload`, `reply_queue`
- `RactorJobError` — serialised error: `message`, `backtrace`
- `RobotSpec` — frozen robot descriptor: `name`, `template`, `system_prompt`, `config_hash`, `hook_classes`

## Tool Requirements for Ractor Safety

Tools submitted to `RactorWorkerPool` must:
1. Be instantiated fresh per call (no shared mutable state)
2. Accept only Ractor-shareable arguments (frozen strings, numbers, frozen hashes)
3. Return a value that can be `Ractor.make_shareable` (frozen or deep-freezable)

LLM calls via `ruby_llm` are NOT Ractor-safe — do not submit tools that call the LLM to the pool.

## Key Constraints

- Shutdown is via poison-pill (one `nil` per worker) — always call `shutdown` to avoid orphaned Ractors.
- `RactorNetworkScheduler.process_job` and `RactorWorkerPool.process_job` must be class methods — Ractors cannot call instance methods on objects defined outside their scope.
- `RobotSpec#hook_classes` must be an array of frozen class references, not instances.

## Testing

- Minitest with SimpleCov (branch coverage tracked, no minimum threshold enforced yet)
- Tests use RobotLab stubs (the full `robot_lab` gem is NOT loaded in tests — see `test_helper.rb`)
- Coverage baseline: ~55% line / ~32% branch
