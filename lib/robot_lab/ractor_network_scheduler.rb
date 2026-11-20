# frozen_string_literal: true

module RobotLab
  # Schedules frozen robot task descriptions across Ractor workers.
  #
  # The scheduler distributes frozen RobotSpec payloads; each worker
  # constructs a fresh Robot and runs it (LLM call included) inside the
  # Ractor, then returns a frozen result. One thread per ready task waits
  # on the worker's reply; no robot work happens on those threads.
  #
  # NOTE: robot_lab core cannot yet build a Robot inside a non-main Ractor
  # (RunConfig's define_method accessors are not Ractor-shareable), so real
  # robots currently fail with RobotLab::Error. The scheduling itself is
  # exercised by overriding execute_spec (see examples/02_ractor_network.rb).
  #
  # Task ordering respects depends_on: tasks are only dispatched once all
  # named dependencies have resolved (same topological semantics as
  # SimpleFlow::Pipeline). Results are keyed by RobotSpec#name, and
  # depends_on entries are matched against those same names.
  #
  # Each task's message is built from its own dependencies' results — see
  # RactorNetworkScheduler.message_for.
  #
  # @example
  #   scheduler = RactorNetworkScheduler.new(memory: shared_memory)
  #   scheduler.run_pipeline([
  #     { spec: analyst_spec, depends_on: :none },
  #     { spec: writer_spec,  depends_on: ["analyst"] }
  #   ], message: "Process this")
  #   scheduler.shutdown
  #
  class RactorNetworkScheduler
    QUEUE_CAPACITY = 256

    # Separator between dependency results in a multi-dependency message.
    RESULT_SEPARATOR = "\n\n"

    attr_reader :memory

    # @param memory [Memory] the network's memory. Accepted for API
    #   compatibility with Network and exposed via #memory, but NOT shared
    #   with workers: a Memory cannot cross a Ractor boundary and no
    #   RactorMemoryProxy is created or handed to worker robots.
    # @param pool_size [Integer, :auto] number of Ractor workers
    def initialize(memory:, pool_size: :auto)
      @memory  = memory
      @work_q  = RactorQueue.new(capacity: QUEUE_CAPACITY)
      @size    = pool_size == :auto ? Etc.nprocessors : pool_size.to_i
      @workers = @size.times.map { spawn_worker(@work_q) }
      @closed  = false
    end

    # Run a single spec and return the result string.
    # @param spec [RobotSpec]
    # @param message [String]
    # @return [String] the robot's last_text_content
    def run_spec(spec, message:)
      execute_spec(spec, message)
    end

    # Run a pipeline of specs in dependency order.
    #
    # @param specs_with_deps [Array<Hash>] each entry has :spec and :depends_on
    # @param message [String] initial message passed to entry-point robots;
    #   dependent robots receive their dependencies' results instead
    #   (see .message_for)
    # @return [Hash<String, String>] name => result for each completed robot
    def run_pipeline(specs_with_deps, message:)
      completed = {}
      remaining = specs_with_deps.dup

      until remaining.empty?
        ready, remaining = partition_ready(remaining, completed)
        raise RobotLab::Error, 'Circular dependency or unresolvable deps in RactorNetworkScheduler' if ready.empty?

        dispatch_ready(ready, completed, message).each do |t|
          name, result = t.value
          completed[name] = result
        end
      end

      completed
    end

    # Gracefully shut down worker Ractors.
    # :reek:UncommunicativeVariableName -- single-char block param (w = worker) is accepted project convention.
    def shutdown
      return if @closed

      @closed = true
      @size.times { @work_q.push(nil) }
      @workers.each do |w|
        w.join
      rescue StandardError
        nil
      end
    end

    # Called inside Ractor worker blocks — must be a class method.
    def self.process_job(job)
      spec    = job.payload[:spec]
      message = job.payload[:message]
      job.reply_queue.push(build_and_run_robot(spec, message))
    rescue StandardError => e
      job.reply_queue.push(wrap_error(e))
    end

    def self.build_and_run_robot(spec, message)
      config = spec.config_hash.empty? ? nil : RobotLab::RunConfig.new(**spec.config_hash.transform_keys(&:to_sym))
      robot  = RobotLab::Robot.new(
        name: spec.name,
        template: spec.template&.to_sym,
        system_prompt: spec.system_prompt,
        config: config
      )
      spec.hook_classes.each { |handler| robot.on(handler) }
      robot.run(message).last_text_content.to_s.freeze
    end

    # Build the message for one task from its dependencies' results.
    #
    # - no dependencies (:none, :optional, or empty) => the fallback message
    # - one dependency  => that dependency's result, unchanged
    # - several         => one "[name]\nresult" block per dependency, in the
    #                      order depends_on declares them, joined by a blank line
    #
    # @param deps [Symbol, Array<String>] the entry's :depends_on value
    # @param completed [Hash<String, String>] name => result of finished tasks
    # @param fallback [String] the pipeline's initial message
    # @return [String]
    def self.message_for(deps, completed, fallback)
      names = dependency_names(deps)
      return fallback if names.empty?
      return completed.fetch(names.first) if names.one?

      names.map { |name| "[#{name}]\n#{completed.fetch(name)}" }.join(RESULT_SEPARATOR)
    end

    # Normalise a :depends_on value to the list of names that must complete first.
    #
    # @param deps [Symbol, Array<String>, nil]
    # @return [Array] empty for :none / :optional / nil
    def self.dependency_names(deps)
      return [] if %i[none optional].include?(deps)

      Array(deps)
    end

    def self.wrap_error(err)
      RobotLab::RactorJobError.new(
        message: err.message.freeze,
        backtrace: (err.backtrace || []).map(&:freeze).freeze
      )
    end

    private

    def execute_spec(spec, message)
      frozen_spec    = ::Ractor.make_shareable(spec)
      frozen_message = message.to_s.freeze
      reply_q        = RactorQueue.new(capacity: 1)

      job = RactorJob.new(
        id: SecureRandom.uuid.freeze,
        type: :robot,
        payload: RactorBoundary.freeze_deep({ spec: frozen_spec, message: frozen_message }),
        reply_queue: reply_q
      )

      @work_q.push(job)
      result = reply_q.pop

      raise RobotLab::Error, "Robot '#{spec.name}' failed in Ractor: #{result.message}" if result.is_a?(RactorJobError)

      result
    end

    def spawn_worker(work_q)
      ::Ractor.new(work_q) do |q|
        loop do
          job = q.pop
          break if job.nil?

          RobotLab::RactorNetworkScheduler.process_job(job)
        end
      end
    end

    # :reek:FeatureEnvy :reek:NestedIterators -- readiness predicate over each entry's depends_on list; the inner all? defines "ready".
    def partition_ready(remaining, completed)
      remaining.partition do |entry|
        self.class.dependency_names(entry[:depends_on]).all? { |d| completed.key?(d) }
      end
    end

    def dispatch_ready(ready, completed, message)
      ready.map do |entry|
        spec = entry[:spec]
        msg  = self.class.message_for(entry[:depends_on], completed, message)
        Thread.new { [spec.name, execute_spec(spec, msg)] }.tap { |t| t.report_on_exception = false }
      end
    end
  end
end
