# frozen_string_literal: true

module RobotLab
  # A pool of Ractor workers that execute CPU-bound, Ractor-safe tools.
  #
  # Work is distributed via a shared RactorQueue. Each worker runs a
  # blocking loop, pops RactorJob instances, dispatches to the named
  # tool class, and pushes the frozen result (or a RactorJobError) to
  # the job's per-job reply_queue.
  #
  # Shutdown uses a poison-pill pattern: one nil sentinel per worker is
  # pushed to the work queue; each worker exits when it pops nil.
  #
  # Only tools that declare +ractor_safe true+ should be submitted.
  # Tool classes are instantiated fresh inside the Ractor for each call.
  #
  # @example
  #   pool = RactorWorkerPool.new(size: 4)
  #   result = pool.submit("MyTool", { "arg" => "value" })
  #   pool.shutdown
  #
  class RactorWorkerPool
    QUEUE_CAPACITY = 1024

    attr_reader :size

    # @param size [Integer, :auto] number of workers (:auto = Etc.nprocessors)
    def initialize(size: :auto)
      @size    = size == :auto ? Etc.nprocessors : size.to_i
      @closed  = false
      @work_q  = RactorQueue.new(capacity: QUEUE_CAPACITY)
      @workers = @size.times.map { spawn_worker(@work_q) }
    end

    # Submit a tool job and block until the result is available.
    #
    # @param tool_class_name [String] fully-qualified Ruby constant name of the tool class
    # @param args [Hash] tool arguments (deep-frozen before crossing Ractor boundary)
    # @return [Object] the tool's return value
    # @raise [ToolError] if the tool raises inside the Ractor
    def submit(tool_class_name, args)
      raise ToolError, 'Pool is shut down' if @closed

      reply_q = RactorQueue.new(capacity: 1)
      payload = RactorBoundary.freeze_deep({ tool_class: tool_class_name.to_s, args: args })

      job = RactorJob.new(
        id: SecureRandom.uuid.freeze,
        type: :tool,
        payload: payload,
        reply_queue: reply_q
      )

      @work_q.push(job)
      result = reply_q.pop

      raise ToolError, "Tool '#{tool_class_name}' failed in Ractor: #{result.message}" if result.is_a?(RactorJobError)

      result
    end

    # Gracefully shut down the pool via poison-pill pattern.
    # @return [void]
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
      tool_class    = Object.const_get(job.payload[:tool_class])
      result        = tool_class.new.execute(**job.payload[:args].transform_keys(&:to_sym))
      frozen_result = ::Ractor.make_shareable(result.frozen? ? result : result.dup.freeze)
      job.reply_queue.push(frozen_result)
    rescue StandardError => e
      job.reply_queue.push(wrap_error(e))
    end

    def self.wrap_error(err)
      RobotLab::RactorJobError.new(
        message: err.message.freeze,
        backtrace: (err.backtrace || []).map(&:freeze).freeze
      )
    end

    private

    def spawn_worker(work_q)
      ::Ractor.new(work_q) do |q|
        loop do
          job = q.pop
          break if job.nil?

          RobotLab::RactorWorkerPool.process_job(job)
        end
      end
    end
  end
end
