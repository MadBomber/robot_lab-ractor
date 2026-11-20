# Ractor Parallelism

RobotLab supports true CPU parallelism via Ruby Ractors — isolated execution contexts that bypass the Global VM Lock (GVL). This guide explains how to put both CPU-bound tools and multi-robot pipelines on parallel hardware threads.

## Why Ractors?

Ruby's standard thread model is I/O-concurrent but CPU-serialized: the GVL means only one thread runs Ruby code at a time. For LLM workflows this is usually fine — robots spend most of their time waiting on the network. But some workloads benefit from real parallel execution:

- **CPU-intensive tools** — text processing, image analysis, embeddings, cryptography
- **Independent robot pipelines** — multiple robots working on unrelated subtasks simultaneously

Ractors bypass the GVL entirely. Each Ractor runs on its own OS thread with no shared mutable state, so multiple Ractors genuinely execute in parallel on multi-core hardware.

## Architecture Overview

RobotLab provides two parallel tracks:

```
┌─────────────────────────────────────────────────────┐
│                   Your Application                   │
├─────────────────────────────┬───────────────────────┤
│   Track 1: CPU-bound Tools  │  Track 2: Robots       │
│                             │                        │
│  Tool#ractor_safe           │  Network               │
│      ↓                      │  parallel_mode: :ractor│
│  RactorWorkerPool           │      ↓                 │
│  (N Ractor workers)         │  RactorNetworkScheduler│
│                             │  (N Ractor workers)    │
├─────────────────────────────┴───────────────────────┤
│           Shared Infrastructure                      │
│   RactorBoundary · RactorJob · RactorMemoryProxy     │
└─────────────────────────────────────────────────────┘
```

**Track 1** routes Ractor-safe tools through a global worker pool instead of calling them inline. The robot never notices — it still gets back a result string.

**Track 2** replaces the `SimpleFlow::Pipeline` executor for a network with a `RactorNetworkScheduler` that dispatches frozen robot specs to Ractor workers, respecting `depends_on` ordering.

Both tracks share the same frozen-data convention: all values crossing a Ractor boundary must be Ractor-shareable.

---

## Track 1: CPU-Bound Tools

### Declaring a Tool as Ractor-Safe

Add `ractor_safe true` to any `RobotLab::Tool` subclass (the DSL and the pool routing live in `RobotLab::Tool`, not `RubyLLM::Tool`):

```ruby
class TranscribeAudio < RobotLab::Tool
  ractor_safe true

  description "Transcribe an audio file to text"

  parameter :path,   type: :string, description: "Absolute path to the audio file"
  parameter :format, type: :string, description: "Audio format (wav, mp3, ogg)", required: false

  def execute(path:, format: "wav")
    # Pure computation — no shared mutable state, no IO closures
    AudioTranscriber.run(path, format: format)
  end
end
```

When a robot calls this tool, RobotLab automatically routes the call through the global `RactorWorkerPool` rather than executing it inline. The robot is unaffected — it receives the result string as normal.

`ractor_safe` is inherited. If you declare it on a base class, all subclasses are also treated as Ractor-safe:

```ruby
class BaseAudioTool < RobotLab::Tool
  ractor_safe true
end

class TranscribeAudio < BaseAudioTool  # also ractor_safe
  # ...
end

class DetectLanguage < BaseAudioTool   # also ractor_safe
  # ...
end
```

### What Makes a Tool Ractor-Safe?

A tool is safe to run inside a Ractor when its `execute` method:

- Uses only **frozen or locally-created** objects
- Does **not** read or write class-level mutable state (class variables, module-level globals)
- Does **not** hold references to closures, Procs, or lambdas defined outside the Ractor
- Does **not** use non-Ractor-safe C extensions (most pure-Ruby code is fine)

```ruby
# Safe: all inputs arrive as frozen args; result is fresh
class HashContent < RobotLab::Tool
  ractor_safe true
  description "SHA-256 hash of a string"
  parameter :text, type: :string, description: "Text to hash"

  def execute(text:)
    require "digest"
    Digest::SHA256.hexdigest(text)
  end
end

# Not safe: reads and writes @@cache (shared mutable state)
class CachedLookup < RobotLab::Tool
  @@cache = {}  # mutable class variable — NOT Ractor-safe

  def execute(key:)
    @@cache[key] ||= expensive_lookup(key)
  end
end
```

### Configuring the Worker Pool

The global pool is created lazily on first use with one worker per CPU core (`Etc.nprocessors`). Its size is not currently configurable: `RobotLab.ractor_pool` looks for a `ractor_pool_size` setting on `RobotLab.config`, but core's `Config` does not define one (`config.ractor_pool_size = 8` raises `NoMethodError`), and the `ractor_pool_size` field that `RunConfig` accepts is not read when the pool is built.

If you need a specific worker count, build a pool yourself and submit to it directly:

```ruby
pool   = RobotLab::RactorWorkerPool.new(size: 4)   # default size: :auto (Etc.nprocessors)
result = pool.submit("HashContent", { text: "hello" })
pool.shutdown
```

Access the shared pool directly:

```ruby
pool = RobotLab.ractor_pool       # RactorWorkerPool instance
RobotLab.shutdown_ractor_pool     # graceful shutdown (poison-pill pattern)
```

---

## Track 2: Parallel Robot Networks

### Enabling Ractor Mode

Pass `parallel_mode: :ractor` to `RobotLab::Network.new` (the `RobotLab.create_network` factory does not accept `parallel_mode`):

```ruby
network = RobotLab::Network.new(name: "analysis", parallel_mode: :ractor) do
  task :fetch,     fetcher_robot,    depends_on: :none
  task :sentiment, sentiment_robot,  depends_on: [:fetch]
  task :entities,  entity_robot,     depends_on: [:fetch]
  task :summarize, summary_robot,    depends_on: [:sentiment, :entities]
end

result = network.run(message: "Analyze customer feedback")
```

When `parallel_mode: :ractor` is set, `Network#run` delegates to `RactorNetworkScheduler` instead of the default `SimpleFlow::Pipeline` executor. The default is `:async` (unchanged behavior).

Each robot's `name` must match its task name: the scheduler keys completed results by robot name, while `depends_on` refers to task names. If they differ, dependent tasks never become ready and `run` raises `RobotLab::Error` ("Circular dependency or unresolvable deps").

!!! warning "Live robot runs do not work in Ractor mode yet"
    A `RobotLab::Robot` cannot currently be constructed inside a non-main Ractor: `Robot.new` raises `defined with an un-shareable Proc in a different Ractor` from core's `RunConfig` accessors. A real `network.run` in `:ractor` mode therefore fails with `RobotLab::Error: Robot '<name>' failed in Ractor: ...`. The scheduling machinery itself (waves, dependency ordering, result Hash) works and is demonstrated with a simulated scheduler in `examples/02_ractor_network.rb`.

### How It Works

The network builds a `RobotSpec` — a frozen, Ractor-shareable description — for each robot, then hands them to the scheduler, which dispatches them in dependency order:

1. **Partition** tasks into waves: tasks whose dependencies are all resolved are dispatched together.
2. **Each wave** spawns one thread per task; each thread submits a `RactorJob` to the shared work queue and blocks on the per-job reply queue.
3. **Worker Ractors** pop jobs, construct a fresh `Robot` from the spec, call `robot.run(message)`, and push the frozen result string back.
4. **Everything in step 3 runs inside the worker Ractor**, including the LLM call made by `robot.run` — there is no hand-off back to a thread.

```
Wave 1:  [ fetch ]
           ↓ fetch's result is the message for both dependents
Wave 2:  [ sentiment | entities ]   ← run in parallel
           ↓ both results are combined into summarize's message
Wave 3:  [ summarize ]
```

Each task's message is built from its own dependencies' results (`RactorNetworkScheduler.message_for`):

| Dependencies | Message the robot receives |
|---|---|
| none (`:none` / `:optional`) | the original `message` passed to `run` |
| one | that dependency's result, unchanged |
| several | one `[name]` line followed by that dependency's result, per dependency, in the order `depends_on` lists them, separated by a blank line |

For `summarize` above, the message is:

```
[sentiment]
<sentiment result>

[entities]
<entities result>
```

The return value of `run` is a `Hash` mapping robot name strings to their result strings:

```ruby
results = network.run(message: "Analyze this")
# => { "fetch" => "...", "sentiment" => "positive", "entities" => "...", "summarize" => "..." }
```

### Dependency Ordering

Dependency semantics mirror those of `SimpleFlow::Pipeline`:

| `depends_on` value | Meaning |
|---|---|
| `:none` | Entry-point task; dispatched in the first wave |
| `:optional` | Runs in the first wave (not blocked by anything) |
| `["task_a", "task_b"]` | Waits until both `task_a` and `task_b` complete |

```ruby
RobotLab::Network.new(name: "pipeline", parallel_mode: :ractor) do
  task :ingest,    ingester,  depends_on: :none
  task :classify,  classifier, depends_on: ["ingest"]
  task :summarize, summarizer, depends_on: ["ingest"]
  task :report,    reporter,  depends_on: ["classify", "summarize"]
end
```

---

## Shared Memory Across Ractors

Robots running in Ractor workers cannot share a standard `Memory` instance directly — it contains mutable Ruby objects. RobotLab solves this with `RactorMemoryProxy`, which wraps a `Memory` via `Ractor::Wrapper`.

You typically interact with the proxy from the thread side (before and after Ractor dispatch), not from inside workers. Workers return a frozen result string; the scheduler stores it in `completed` for subsequent waves. The scheduler does not create a proxy or pass one to worker robots — its `memory:` argument is only retained (readable as `scheduler.memory`), so wiring a proxy into your own Ractor code is up to you.

For cases where you need Ractor workers to write into shared memory at runtime, use the proxy's Ractor-shareable stub:

```ruby
memory = RobotLab::Memory.new
proxy  = RobotLab::RactorMemoryProxy.new(memory)

# Pass the stub (not the proxy) into Ractor.new
Ractor.new(proxy.stub) do |mem|
  mem.set(:status, "done")
  mem.get(:status)   # => "done"
end.value

memory.get(:status)  # => "done"

proxy.shutdown
```

Values written via `set` are automatically deep-frozen before crossing the boundary.

---

## Hooks in Ractor Workers

`RactorNetworkScheduler` carries a robot's registered `RobotLab::Hook` handler
classes across the Ractor boundary so the full hook pipeline still fires
inside each worker.

When the network builds a `RobotSpec` for the scheduler, it collects handler classes from all
three registration levels and stores them in the frozen `hook_classes` field:

```ruby
def ractor_hook_classes_for(robot)
  [RobotLab.hooks, @hooks, robot.hooks]
    .flat_map { |registry| registry.registrations.map(&:handler_class) }
    .uniq
    .freeze
end
```

| Registration level | Collected by |
|---|---|
| `RobotLab.on(Hook)` | `RobotLab.hooks` (global) |
| `network.on(Hook)` | `@hooks` (network) |
| `robot.on(Hook)` | `robot.hooks` (robot) |

Inside each worker, the scheduler re-registers the handlers on the freshly
built robot before running it:

```ruby
spec.hook_classes.each { |handler| robot.on(handler) }
robot.run(message)   # full hook pipeline fires here
```

This works because a Hook handler is a Ruby **class**, and classes are
Ractor-shareable constants — they cross the boundary without any
serialization.

### Writing a Ractor-Safe Hook

A hook handler that may run inside a Ractor worker must follow the same
statelessness rules as a Ractor-safe tool:

- **No class-level state.** `@ivars` set on the class object live in the main
  Ractor; non-main Ractors cannot read or write them, even when the values
  themselves would be shareable.
- **Accumulate events on the context, not the class.** Push results into
  `ctx.local` (a plain object local to that Ractor's run) and return them as
  part of the worker's result tuple so the main thread can aggregate them
  after `Ractor#value`.
- **Avoid `$stdout.puts` for anything you need interleaved with main-thread
  output.** Output from non-main Ractors is buffered per-Ractor and only
  flushes at Ractor exit. `Kernel#warn` is silently dropped. Reading the
  `STDOUT` constant raises `IsolationError`. `$stderr.puts` and a
  `File.open(frozen_path, "a")` opened fresh inside the worker are both safe.
- **`on_error` fires inside the failing Ractor**, before the error propagates
  back to the main thread. Surface whatever you need via the return tuple —
  the main thread only learns of the failure when it calls `worker.value`.

`examples/03_ractor_hooks.rb` walks through all of this with two example
handlers (`TraceHook`, `PerfHook`) plus `RobotLab::Xyzzy` — a fully
Ractor-safe tracer covering all five hook families (`run`, `llm_generation`,
`tool_call`, `network_run`, `task`) — run directly against the hook mechanic
without constructing a `RobotLab::Robot` (which cannot be built inside a
non-main Ractor today — see the warning under Track 2).

---

## The Frozen-Data Contract

Everything that crosses a Ractor boundary must be Ractor-shareable: frozen strings, frozen hashes, frozen arrays, `Data.define` structs, and integers/symbols/nil.

`RactorBoundary.freeze_deep` recursively freezes a nested Hash/Array structure and raises `RactorBoundaryError` if it encounters something that cannot be made shareable (like a `StringIO` or a `Proc`):

```ruby
safe = RobotLab::RactorBoundary.freeze_deep({ key: "value", tags: ["a", "b"] })
# => { key: "value", tags: ["a", "b"] } (all frozen)

RobotLab::RactorBoundary.freeze_deep(StringIO.new)
# => raises RobotLab::RactorBoundaryError
```

You generally do not need to call this directly — `RactorWorkerPool#submit` and `RactorMemoryProxy#set` call it for you. But it is public if you build tooling on top.

---

## Error Handling

### Tool Errors

If a Ractor-safe tool raises inside a worker, the worker catches the error, wraps it in a `RactorJobError`, and sends it back through the reply queue. The pool unwraps it and re-raises as `RobotLab::ToolError`:

```ruby
begin
  pool.submit("MyTool", { input: "bad data" })
rescue RobotLab::ToolError => e
  puts e.message  # "Tool 'MyTool' failed in Ractor: ..."
end
```

### Robot Pipeline Errors

The scheduler raises `RobotLab::Error` if a robot fails inside a Ractor worker:

```ruby
begin
  network.run(message: "go")
rescue RobotLab::Error => e
  puts e.message  # "Robot 'summarize' failed in Ractor: ..."
end
```

### Boundary Errors

Passing unshareable data raises `RobotLab::RactorBoundaryError` before any Ractor is involved:

```ruby
begin
  pool.submit("MyTool", { io: StringIO.new })
rescue RobotLab::RactorBoundaryError => e
  puts e.message  # "Cannot make value Ractor-shareable: ..."
end
```

---

## Configuration Reference

| Parameter | Where | Default | Description |
|---|---|---|---|
| `size` | `RactorWorkerPool.new` | `:auto` (`Etc.nprocessors`) | Worker count for a pool you build yourself; the global `RobotLab.ractor_pool` always uses `:auto` |
| `ractor_pool_size` | `RunConfig` | — | Accepted as a field but not currently read by the pool |
| `parallel_mode` | `Network.new` | `:async` | `:async` (SimpleFlow) or `:ractor` (RactorNetworkScheduler) |

---

## Best Practices

### 1. Profile Before Reaching for Ractors

Ractors add overhead: freezing data, queue coordination, thread synchronization. For fast tools or networks with few tasks, standard threads are often faster. Measure first.

### 2. Keep Tool State Stateless

The safest Ractor-safe tool is a pure function:

```ruby
class NormalizeText < RobotLab::Tool
  ractor_safe true
  description "Strip and collapse whitespace in a string"
  parameter :text, type: :string, description: "Input text"

  def execute(text:)
    text.strip.squeeze(" ")
  end
end
```

Even pure-looking stdlib calls can fail in a worker: `String#unicode_normalize`, for example, reads unshareable constants (`UnicodeNormalize::REGEXP_K`) and raises `Ractor::IsolationError`, surfaced as a `RobotLab::ToolError`.

### 3. Freeze Tool Return Values

Tool results travel back through the reply queue — freeze them proactively so the worker does not have to `dup` the result before making it shareable:

```ruby
def execute(id:)
  { id: id, name: "result" }.freeze
end
```

### 4. Parallel Mode Doesn't Share Robot Instances

Each Ractor worker constructs a **fresh Robot** from the frozen spec. Side-effects on the original robot objects (callbacks, in-memory state) are not visible inside workers. Use `Memory` (via a `RactorMemoryProxy` stub you pass in yourself) for shared state.

### 5. LLM Calls Are Not Ractor-Safe

The scheduler does not move LLM calls onto threads: each worker builds its robot and calls `robot.run` inside the Ractor. Because robot construction is not Ractor-safe today (see the warning under Track 2), keep LLM-calling robots on the default `:async` mode, and never mark a tool that calls an LLM as `ractor_safe`.

### 6. Shut Down the Pool Cleanly

Always shut down the global pool before exiting, especially in scripts:

```ruby
at_exit { RobotLab.shutdown_ractor_pool }
```

---

## Constraints and Limitations

- **No closures across boundaries.** Procs and lambdas cannot cross Ractor boundaries. Callbacks (`on_tool_call`, `on_tool_result`) registered on the outer robot are not available inside workers.
- **No mutable class-level state.** Class variables and module globals accessed from `execute` must be frozen.
- **`parallel_mode: :ractor` returns a plain Hash**, not a `SimpleFlow::Result`. If downstream code depends on `result.context` or `result.value`, use `:async` mode.
- **Memory subscriptions stay on the thread side.** Subscription callbacks are closures, so they cannot be registered from inside a worker. Writes made through the proxy stub are applied to the wrapped `Memory`, so subscriptions already registered on it do fire — in the Ractor that owns the `Memory`, not in the worker.
- **Ruby version.** This gem requires Ruby 4.0.9+. `Ractor#value` / `Ractor#join` are the supported APIs from Ruby 4.0 onwards (`Ractor#take` was removed).

---

## Runnable Examples

- `examples/01_ractor_tools.rb` — CPU-bound tools routed through `RactorWorkerPool`
- `examples/02_ractor_network.rb` — a robot network run via `RactorNetworkScheduler`
- `examples/03_ractor_hooks.rb` — the hook system firing inside Ractor workers (no LLM API key required)

```bash
bundle exec ruby examples/03_ractor_hooks.rb
```

## Next Steps

These live in the RobotLab core documentation:

- [Using Tools](https://madbomber.github.io/robot_lab/guides/using-tools/) — Tool definitions and configuration
- [Creating Networks](https://madbomber.github.io/robot_lab/guides/creating-networks/) — Network orchestration patterns
- [Memory System](https://madbomber.github.io/robot_lab/guides/memory/) — Shared data between robots
- [API Reference: Network](https://madbomber.github.io/robot_lab/api/core/network/) — Complete Network API
