# frozen_string_literal: true

require 'test_helper'
require 'etc'
require 'securerandom'
require 'robot_lab/ractor_network_scheduler'

module RobotLab
  class RactorNetworkSchedulerTest < Minitest::Test
    # Records the message each spec receives instead of building a Robot,
    # so wave ordering and message routing run without a model.
    class RecordingScheduler < RobotLab::RactorNetworkScheduler
      def received
        @received ||= {}
      end

      private

      def execute_spec(spec, message)
        received_lock.synchronize { received[spec.name] = message }
        "#{spec.name}-out"
      end

      def received_lock
        @received_lock ||= Mutex.new
      end
    end

    def setup
      @memory    = Object.new
      @scheduler = RecordingScheduler.new(memory: @memory, pool_size: 1)
    end

    def teardown
      @scheduler.shutdown
    end

    # --- message_for (pure) -------------------------------------------------

    def test_message_for_no_dependencies_returns_fallback
      completed = { 'earlier' => 'earlier-out' }

      assert_equal 'go', RactorNetworkScheduler.message_for(:none, completed, 'go')
      assert_equal 'go', RactorNetworkScheduler.message_for(:optional, completed, 'go')
      assert_equal 'go', RactorNetworkScheduler.message_for([], completed, 'go')
    end

    def test_message_for_single_dependency_returns_its_result_unchanged
      completed = { 'a' => 'a-out', 'z' => 'z-out' }

      assert_equal 'a-out', RactorNetworkScheduler.message_for(['a'], completed, 'go')
    end

    def test_message_for_multiple_dependencies_uses_declared_order
      completed = { 'b' => 'b-out', 'a' => 'a-out', 'unrelated' => 'x' }

      assert_equal "[a]\na-out\n\n[b]\nb-out", RactorNetworkScheduler.message_for(%w[a b], completed, 'go')
      assert_equal "[b]\nb-out\n\n[a]\na-out", RactorNetworkScheduler.message_for(%w[b a], completed, 'go')
    end

    def test_message_for_missing_dependency_raises
      assert_raises(KeyError) { RactorNetworkScheduler.message_for(['nope'], {}, 'go') }
    end

    def test_dependency_names
      assert_empty RactorNetworkScheduler.dependency_names(:none)
      assert_empty RactorNetworkScheduler.dependency_names(:optional)
      assert_empty RactorNetworkScheduler.dependency_names(nil)
      assert_equal %w[a b], RactorNetworkScheduler.dependency_names(%w[a b])
      assert_equal ['a'], RactorNetworkScheduler.dependency_names('a')
    end

    # --- run_pipeline -------------------------------------------------------

    # Regression: a dependent used to receive whichever result completed last
    # (here "side-out"), not the output of the task it depends on.
    def test_dependent_receives_its_own_dependency_not_the_last_completed
      results = @scheduler.run_pipeline(
        [entry('first'), entry('side'), entry('second', ['first'])],
        message: 'go'
      )

      assert_equal 'go',        @scheduler.received['first']
      assert_equal 'go',        @scheduler.received['side']
      assert_equal 'first-out', @scheduler.received['second']
      assert_equal %w[first side second], results.keys
    end

    def test_multi_dependency_task_receives_all_dependency_outputs
      @scheduler.run_pipeline(
        [entry('a'), entry('b'), entry('c'), entry('report', %w[b a])],
        message: 'go'
      )

      assert_equal "[b]\nb-out\n\n[a]\na-out", @scheduler.received['report']
    end

    def test_optional_task_runs_in_first_wave_with_initial_message
      @scheduler.run_pipeline([entry('a'), entry('opt', :optional)], message: 'go')

      assert_equal 'go', @scheduler.received['opt']
    end

    def test_unresolvable_dependency_raises
      error = assert_raises(RobotLab::Error) do
        @scheduler.run_pipeline([entry('a'), entry('b', ['missing'])], message: 'go')
      end

      assert_match(/unresolvable deps/, error.message)
    end

    # --- memory -------------------------------------------------------------

    def test_memory_is_retained_and_readable
      assert_same @memory, @scheduler.memory
    end

    def test_shutdown_is_idempotent
      @scheduler.shutdown
      @scheduler.shutdown
    end

    private

    def entry(name, deps = :none)
      spec = RobotLab::RobotSpec.new(name: name, template: nil, system_prompt: nil, config_hash: {}.freeze)
      { spec: spec, depends_on: deps }
    end
  end
end
