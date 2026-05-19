## [Unreleased]

## [0.2.1] - 2026-05-19

### Added
- `RactorWorkerPool` — shared pool of Ractor workers; tools marked `ractor_safe true` are automatically routed through it instead of running inline
- `RactorNetworkScheduler` — DAG-aware parallel execution of robot networks using Ractors; activated via `parallel_mode: :ractor` on a network
- `RactorBoundary` — `freeze_deep` utility for making values Ractor-shareable; raises `RactorBoundaryError` for values that cannot cross Ractor boundaries
- `RactorMemoryProxy` — thread-safe proxy exposing `RobotLab::Memory` to Ractor workers via `Ractor::Wrapper`
- `RactorJob` — Ractor-shareable frozen job value object used internally by the pool and scheduler
- `ractor_safe` class-level DSL for `RubyLLM::Tool` / `RobotLab::Tool` subclasses; inherited by subclasses
- `RobotLab.ractor_pool` / `.shutdown_ractor_pool` — process-level pool lifecycle methods added to the `RobotLab` module
- Ractor Parallelism guide (`docs/guides/ractor-parallelism.md`) covering both CPU-bound tools and parallel network pipelines

### Changed
- Version synchronized with robot_lab core 0.2.1

## [0.1.0] - 2026-05-07

- Initial release
