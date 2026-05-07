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

## CPU-Bound Tools

Mark a tool `ractor_safe true` and RobotLab automatically routes its calls through the global `RactorWorkerPool` instead of running inline:

```ruby
class TranscribeAudio < RubyLLM::Tool
  ractor_safe true
  description "Transcribe an audio file"
  param :path, type: :string, desc: "Path to audio file"

  def execute(path:)
    AudioTranscriber.run(path)  # pure computation, no shared mutable state
  end
end

robot = RobotLab.build(
  name: "transcriber",
  system_prompt: "You transcribe audio files.",
  local_tools: [TranscribeAudio]
)

result = robot.run("Transcribe /recordings/meeting.mp3")
puts result.last_text_content
```

## Parallel Robot Networks

Pass `parallel_mode: :ractor` when creating a network to dispatch independent robots across hardware threads simultaneously:

```ruby
network = RobotLab.create_network(name: "analysis", parallel_mode: :ractor) do
  task :fetch,     fetcher_robot,    depends_on: :none
  task :sentiment, sentiment_robot,  depends_on: [:fetch]
  task :entities,  entity_robot,     depends_on: [:fetch]   # runs in parallel with :sentiment
  task :summarize, summary_robot,    depends_on: [:sentiment, :entities]
end

results = network.run(message: "Analyze customer feedback")
# => { "fetch" => "...", "sentiment" => "positive", "entities" => "...", "summarize" => "..." }
```

The scheduler builds a DAG from the `depends_on:` declarations and fires each stage as soon as its dependencies resolve.

## Pool Management

```ruby
# Pool is lazily created on first use
pool = RobotLab.ractor_pool

# Drain and shut down explicitly (e.g. at process exit)
RobotLab.shutdown_ractor_pool
```

## Constraints

Because Ractors are isolated execution contexts that bypass Ruby's GVL, objects passed into them must be deeply frozen (no shared mutable state). The `RactorBoundary` utility handles this automatically for tool arguments. Your tool's `execute` method must not reference any unfrozen constants or class-level mutable state.

## Links

- [Ractor Parallelism Guide](https://madbomber.github.io/robot_lab-ractor/guides/ractor-parallelism)
- [RobotLab Core](https://github.com/MadBomber/robot_lab)
- [RubyGems](https://rubygems.org/gems/robot_lab-ractor)

## License

MIT License - Copyright (c) 2025 Dewayne VanHoozer

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/MadBomber/robot_lab-ractor.
