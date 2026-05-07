# robot_lab-ractor

Ractor-based CPU parallelism for the [RobotLab](https://github.com/MadBomber/robot_lab) LLM agent framework.

> [!CAUTION]
> This gem is under active development. APIs may change without notice.

## What it provides

- **`RactorWorkerPool`** — shared pool of Ractor workers for CPU-bound tools; tools marked `ractor_safe true` are routed through it automatically
- **`RactorNetworkScheduler`** — DAG-aware parallel execution of robot pipelines using Ractors
- **`RactorBoundary`** — deep-freeze utilities for safely sharing objects across Ractor boundaries
- **`RactorMemoryProxy`** — thread-safe proxy exposing `RobotLab::Memory` to Ractor workers via `Ractor::Wrapper`
- **`RobotLab.ractor_pool` / `.shutdown_ractor_pool`** — process-level pool management added to the `RobotLab` module

## Installation

Add to your Gemfile:

```ruby
gem "robot_lab"
gem "robot_lab-ractor"
```

## Quick Example

```ruby
require "robot_lab"
require "robot_lab/ractor"

# Mark a tool as Ractor-safe to route it through the pool
class NumberCruncher < RobotLab::Tool
  description "CPU-intensive calculation"
  param :n, type: "number", desc: "Input"
  ractor_safe true

  def execute(n:)
    # runs in a Ractor worker, not the main thread
    (1..n.to_i).sum
  end
end

robot = RobotLab.build(
  name: "cruncher",
  system_prompt: "You crunch numbers.",
  local_tools: [NumberCruncher]
)

result = robot.run("Sum all numbers from 1 to 1000.")
puts result.last_text_content
```

## Pool Management

```ruby
# Pool is lazily created on first use
pool = RobotLab.ractor_pool

# Drain and shut down explicitly (e.g. at process exit)
RobotLab.shutdown_ractor_pool
```

## Links

- [Ractor Parallelism Guide](guides/ractor-parallelism.md)
- [Implementation Plan](superpowers/plans/2026-04-14-ractor-integration.md)
- [Design Spec](superpowers/specs/2026-04-14-ractor-integration-design.md)
- [RobotLab Core](https://github.com/MadBomber/robot_lab)
- [RubyGems](https://rubygems.org/gems/robot_lab-ractor)
