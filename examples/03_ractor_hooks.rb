#!/usr/bin/env ruby
# frozen_string_literal: true

# Example 31: Hook System in Ractor Context
#
# Demonstrates that RobotLab::Hook handler classes fire correctly inside
# Ractor workers. Handler classes are Ruby constants, so they cross Ractor
# boundaries natively and their class methods run in whichever Ractor calls them.
#
# The demo bypasses RobotLab::Robot and ruby_llm entirely (ruby_llm has class-
# level Proc callbacks that prevent construction inside Ractors today). Instead
# it calls TraceHook / PerfHook directly with a minimal mock context, isolating
# the hook mechanic from the LLM layer.
#
# Concepts covered:
#   - Handler classes are Ractor-shareable (they are Ruby constants)
#   - Hook class methods fire inside named Ractor workers
#   - Hooks must be stateless in Ractor context — no class-level @ivars
#   - Events accumulate in ctx.local (Ractor-local object); returned in result tuple
#   - Timing aggregated on main thread from Ractor return values
#   - on_error fires inside the failing Ractor; events surface via return tuple
#   - RobotSpec.hook_classes: how registries feed handler classes to workers
#   - Xyzzy covers all five hook families; fully Ractor-safe (no class-level state)
#
# I/O note (Ruby 4.x):
#   $stdout.puts from non-main Ractors is buffered per-Ractor and flushes at
#   Ractor exit — not interleaved with main-thread output. Kernel#warn is
#   silently dropped. The STDOUT constant raises IsolationError.
#   Correct pattern: accumulate events in ctx.local, return via result tuple.
#
# Usage (no LLM API key required):
#   bundle exec ruby examples/03_ractor_hooks.rb

require_relative "common"
require_relative "../../robot_lab/examples/xyzzy"

# ---------------------------------------------------------------------------
# Minimal context objects — all top-level constants so Ractors can reach them
# ---------------------------------------------------------------------------
DemoRobot   = Data.define(:name)
DemoReply   = Data.define(:reply)
DemoNetwork = Data.define(:name)   # used by network-run hook contexts (§5)

# Lean context for network_run hooks — carries a network, not a robot.
class DemoNetCtx
  attr_reader   :network
  attr_accessor :request, :local

  def initialize(name:, request: nil)
    @network = DemoNetwork.new(name: name.freeze)
    @request = request
    @local   = nil
  end
end

# Lean context for task hooks — carries a task name string.
class DemoTaskCtx
  attr_reader   :task
  attr_accessor :request, :local

  def initialize(task:, request: nil)
    @task    = task.freeze
    @request = request
    @local   = nil
  end
end

# Lean stand-in for RobotLab's RunHookContext.
# TraceHook and PerfHook only need: robot.name, response&.reply, error.message
class DemoCtx
  attr_reader   :robot, :request
  attr_accessor :response, :error, :local

  def initialize(name:, request: nil)
    @robot    = DemoRobot.new(name: name.freeze)
    @request  = request
    @response = nil
    @error    = nil
    @local    = []   # accumulates hook event strings for this Ractor's run
  end
end

# ---------------------------------------------------------------------------
# Hook handler classes — stateless by design
#
# Key Ractor rules:
#   - A hook class IS a Ruby constant and IS Ractor-shareable.
#   - But class-level instance variables (@events, @mutex, …) live in the
#     class object in the main Ractor. Non-main Ractors cannot read or write
#     them — IsolationError even if the values would be shareable.
#   - $stdout.puts from non-main Ractors is buffered per-Ractor, flushing at
#     Ractor exit. Output does not interleave with the main thread.
#
# Correct pattern: push events into ctx.local (a Ractor-local Array created
# inside the worker). The caller returns ctx.local as part of its result tuple
# so the main thread can aggregate and display the events.
# ---------------------------------------------------------------------------

# TraceHook records every lifecycle phase in ctx.local.
# Stateless: no class-level storage — safe to call from any Ractor.
class TraceHook < RobotLab::Hook
  self.namespace = :trace

  class << self
    def before_run(ctx)
      ctx.local << "[trace] before_run  robot=#{ctx.robot.name.ljust(14)} ractor=#{worker_label}"
    end

    def after_run(ctx)
      reply = ctx.response&.reply.to_s[0, 44]
      ctx.local << "[trace] after_run   robot=#{ctx.robot.name.ljust(14)} ractor=#{worker_label}  #{reply.inspect}"
    end

    def on_error(ctx)
      ctx.local << "[trace] on_error    robot=#{ctx.robot.name.ljust(14)} ractor=#{worker_label}  #{ctx.error.message[0, 48].inspect}"
    end

    private

    def worker_label
      r = Ractor.current
      r == Ractor.main ? "main" : (r.name || "ractor")
    end
  end
end

# PerfHook times each around_run call and stores the result in ctx.local.
# Returns [block_result, elapsed_ms] so the caller can include timing in
# the Ractor return tuple without any shared state.
class PerfHook < RobotLab::Hook
  self.namespace = :perf

  class << self
    def around_run(ctx, &block)
      t0     = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = block.call
      ms     = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1_000).round(2)
      ctx.local << "[perf]  around_run  robot=#{ctx.robot.name.ljust(14)} ractor=#{worker_label}  #{ms}ms"
      [result, ms]
    end

    private

    def worker_label
      r = Ractor.current
      r == Ractor.main ? "main" : (r.name || "ractor")
    end
  end
end

# ===========================================================================
banner("Hook System in Ractor Context")

# ---------------------------------------------------------------------------
# 1. Shareability: handler classes are Ruby constants
# ---------------------------------------------------------------------------
section("1. Handler classes are Ractor-shareable")

[TraceHook, PerfHook, RobotLab::Xyzzy].each do |klass|
  puts "  Ractor.shareable?(#{klass.name})  =>  #{Ractor.shareable?(klass)}"
end

probe = RobotLab::RobotSpec.new(
  name: "probe", template: nil, system_prompt: "probe".freeze,
  config_hash: {}.freeze, hook_classes: [TraceHook, PerfHook, RobotLab::Xyzzy].freeze
)
puts "  Ractor.shareable?(RobotSpec with hook_classes)  =>  #{Ractor.shareable?(probe)}"
puts
puts "  All three are Ruby constants — Ractor-shareable by definition."
puts "  TraceHook / PerfHook are fully stateless: safe to call inside Ractors."
puts "  Xyzzy is also fully Ractor-safe: LOG_PATH is a frozen constant;"
puts "  each call opens its own File handle and uses PP.pp — no class-level state."

# ---------------------------------------------------------------------------
# 2. Hook methods fire inside named Ractor workers — concurrent execution
# ---------------------------------------------------------------------------
section("2. Hooks firing inside named Ractor workers")
puts "   Three Ractors run concurrently. Each receives [TraceHook, PerfHook, Xyzzy]"
puts "   via its hook_classes argument."
puts "   TraceHook / PerfHook: events accumulate in ctx.local, returned in tuple."
puts "   Xyzzy: writes to $stdout + appends to LOG_PATH — both from inside the"
puts "   Ractor. [xyzzy] lines flush at Ractor exit, appearing after Ractor work."
puts "   Wall time ≈ max(latencies), not their sum — evidence of concurrency."
puts

DEMO_ROBOTS = [
  { name: "researcher",   latency: 0.18 },
  { name: "analyst",      latency: 0.12 },
  { name: "fact_checker", latency: 0.15 }
].freeze

hooks = [TraceHook, PerfHook, RobotLab::Xyzzy].freeze

t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

workers = DEMO_ROBOTS.map do |entry|
  rname   = entry[:name].freeze
  latency = entry[:latency]

  Ractor.new(rname, latency, hooks, name: rname) do |name, lat, hook_classes|
    ctx = DemoCtx.new(name: name, request: "AI governance frameworks")

    # before_run — all handlers that implement it
    hook_classes.each do |h|
      h.before_run(ctx) if h.singleton_class.public_method_defined?(:before_run)
    end

    # around_run — PerfHook wraps and times the simulated work.
    # Returns [result, elapsed_ms]; timing surfaces via the Ractor tuple.
    work_result, ms = PerfHook.around_run(ctx) do
      sleep lat
      "#{name}: #{(lat * 1_000).round}ms of simulated processing".freeze
    end

    ctx.response = DemoReply.new(reply: work_result)

    # after_run — all handlers that implement it
    hook_classes.each do |h|
      h.after_run(ctx) if h.singleton_class.public_method_defined?(:after_run)
    end

    [name, work_result, ms, ctx.local.freeze].freeze
  end
end

results = workers.map(&:value)
wall_ms  = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1_000).round(0)
seq_ms   = DEMO_ROBOTS.sum { |e| e[:latency] * 1_000 }.round(0)

# Flatten results for display
hook_events = results.flat_map { |_, _, _, evts| evts }
timings     = results.to_h { |name, _, ms, _| [name, ms] }

puts "  Hook events (returned via Ractor result tuples):"
hook_events.each { |ev| puts "    #{ev}" }
puts
puts "  Wall time: #{wall_ms}ms  vs  sequential equivalent: #{seq_ms}ms"
puts "  Speedup:   #{(seq_ms.to_f / wall_ms).round(1)}×  (#{DEMO_ROBOTS.size} Ractors running concurrently)"
puts
puts "  Results:"
results.each { |name, val, _ms, _| puts "    #{name.ljust(14)}  #{val.inspect}" }
puts
puts "  Timings (aggregated from return tuples on main thread):"
timings.each { |name, ms| puts "    #{name.ljust(14)}  #{ms}ms" }

# ---------------------------------------------------------------------------
# 3. on_error fires inside the failing Ractor before the error propagates
# ---------------------------------------------------------------------------
section("3. on_error fires inside a Ractor worker")
puts "   Two Ractors run simultaneously. The failing one raises, calls"
puts "   on_error inside the Ractor, collects the event in ctx.local,"
puts "   then returns {error: ..., events: [...]} so the main thread"
puts "   can verify that on_error fired inside the worker."
puts "   (In production the error re-raises as Ractor::RemoteError;"
puts "   events are surfaced here via the return tuple for display.)"
puts

error_workers = [
  Ractor.new("healthy_robot".freeze, [TraceHook, RobotLab::Xyzzy].freeze, name: "healthy_robot") do |name, hook_classes|
    ctx = DemoCtx.new(name: name, request: "run")
    hook_classes.each { |h| h.before_run(ctx) }
    sleep 0.05
    ctx.response = DemoReply.new(reply: "#{name}: ok".freeze)
    hook_classes.each { |h| h.after_run(ctx) }
    { status: :ok, name: name, result: "ok", events: ctx.local.freeze }.freeze
  end,

  Ractor.new("failing_robot".freeze, [TraceHook, RobotLab::Xyzzy].freeze, name: "failing_robot") do |name, hook_classes|
    ctx = DemoCtx.new(name: name, request: "run")
    hook_classes.each { |h| h.before_run(ctx) }
    begin
      raise RuntimeError, "deliberate failure inside Ractor (#{name})"
    rescue RuntimeError => e
      ctx.error = e
      hook_classes.each do |h|
        h.on_error(ctx) if h.singleton_class.public_method_defined?(:on_error)
      end
    end
    # on_error ran inside this Ractor; return events so main thread can see them
    { status: :error, name: name, error: ctx.error.message, events: ctx.local.freeze }.freeze
  end
]

error_workers.each do |worker|
  r = worker.value
  if r[:status] == :ok
    puts "  #{r[:name]}: #{r[:result]}"
    puts "  Events (healthy path):"
    r[:events].each { |ev| puts "    #{ev}" }
  else
    puts "  #{r[:name]}: FAILED — #{r[:error]}"
    puts "  Events (on_error fired inside the Ractor before returning to main):"
    r[:events].each { |ev| puts "    #{ev}" }
  end
end

puts
puts "  The on_error event above was recorded inside the failing Ractor."
puts "  The main thread only learns of the failure when it calls worker.value."

# ---------------------------------------------------------------------------
# 4. How hook_classes flows from registries to Ractor workers
# ---------------------------------------------------------------------------
section("4. Hook delivery via RobotSpec.hook_classes")
puts "  When Network#run_with_ractor_scheduler builds each RobotSpec:"
puts
puts "    def ractor_hook_classes_for(robot)"
puts "      [RobotLab.hooks, @hooks, robot.hooks]"
puts "        .flat_map { |r| r.registrations.map(&:handler_class) }"
puts "        .uniq.freeze"
puts "    end"
puts
puts "  The resulting frozen Array of Class objects is stored in"
puts "  RobotSpec.hook_classes. Inside each Ractor worker:"
puts
puts "    spec.hook_classes.each { |handler| robot.on(handler) }"
puts "    robot.run(message)   # full hook pipeline fires here"
puts
puts "  Because Classes are Ruby constants, they survive the Ractor boundary"
puts "  without any serialization. The hook pipeline inside the worker is"
puts "  identical to what would fire on the main thread — as seen in §2 & §3."
puts
puts "  Registration level  →  collected by"
puts "    RobotLab.on(Hook)   →  RobotLab.hooks  (global)"
puts "    network.on(Hook)    →  @hooks           (network)"
puts "    robot.on(Hook)      →  robot.hooks      (robot)"
puts
puts "  Stateless hook design rules:"
puts "    ✓  Accumulate events in ctx.local — returned in Ractor result tuple"
puts "    ✓  Return timing / metrics via result tuple — aggregated on main thread"
puts "    ✓  $stderr.puts from Ractors — immediate output (unbuffered)"
puts "    ✓  File.open(frozen_path, 'a') inside Ractor — Ractor-local handle, safe"
puts "    ✓  PP.pp / JSON.generate inside Ractors — stdlib, fully Ractor-safe"
puts "    ✗  Class-level @ivars — inaccessible from non-main Ractors"
puts "    ✗  Class variables (@@var) — inaccessible from non-main Ractors"
puts "    ✗  $stdout.puts from Ractors — buffered per-Ractor, not interleaved"
puts "    ✗  Kernel#warn from Ractors — silently dropped (Ruby 4.x)"
puts "    ✗  STDOUT constant — IsolationError from non-main Ractors"

# ---------------------------------------------------------------------------
# 5. Xyzzy: all hook families exercised from the main thread
# ---------------------------------------------------------------------------
section("5. Xyzzy: all five hook families exercised")
puts "   Xyzzy is registered globally (RobotLab.on) and covers every hook"
puts "   family. It is fully Ractor-safe: LOG_PATH is a frozen constant,"
puts "   each call opens its own File handle and formats with PP.pp."
puts "   stdout: one [xyzzy] tagline per call  |  log: full context snapshot"
puts "   Log file: #{RobotLab::Xyzzy::LOG_PATH}"
puts

# ── run family ──
puts "  [run family]"
run_ctx = DemoCtx.new(name: "xyzzy_bot", request: "demonstrate hooks")
RobotLab::Xyzzy.before_run(run_ctx)
RobotLab::Xyzzy.around_run(run_ctx) do
  run_ctx.response = DemoReply.new(reply: "xyzzy_bot: ok".freeze)
end
RobotLab::Xyzzy.after_run(run_ctx)
run_ctx.error = RuntimeError.new("simulated run error")
RobotLab::Xyzzy.on_error(run_ctx)
puts

# ── llm_generation family ──
puts "  [llm_generation family]"
llm_ctx = DemoCtx.new(name: "xyzzy_bot", request: "generate text")
RobotLab::Xyzzy.before_llm_generation(llm_ctx)
RobotLab::Xyzzy.around_llm_generation(llm_ctx) { nil }
RobotLab::Xyzzy.after_llm_generation(llm_ctx)
puts

# ── tool_call family ──
puts "  [tool_call family]"
tool_ctx = DemoCtx.new(name: "xyzzy_bot", request: "call word_stats")
RobotLab::Xyzzy.before_tool_call(tool_ctx)
RobotLab::Xyzzy.around_tool_call(tool_ctx) { nil }
RobotLab::Xyzzy.after_tool_call(tool_ctx)
puts

# ── network_run family ──
puts "  [network_run family]"
net_ctx = DemoNetCtx.new(name: "research_pipeline", request: "run pipeline")
RobotLab::Xyzzy.before_network_run(net_ctx)
RobotLab::Xyzzy.around_network_run(net_ctx) { nil }
RobotLab::Xyzzy.after_network_run(net_ctx)
puts

# ── task family ──
puts "  [task family]"
task_ctx = DemoTaskCtx.new(task: "headline_finder", request: "run task")
RobotLab::Xyzzy.before_task(task_ctx)
RobotLab::Xyzzy.around_task(task_ctx) { nil }
RobotLab::Xyzzy.after_task(task_ctx)

puts
puts "  Context snapshots (with robot/network/task/error details)"
puts "  written to: #{RobotLab::Xyzzy::LOG_PATH}"

puts
hr
