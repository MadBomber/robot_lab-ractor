# frozen_string_literal: true

require 'test_helper'

module RobotLab
  class RactorJobTest < Minitest::Test
    def test_ractor_job_is_shareable
      reply_q = RactorQueue.new(capacity: 1)
      job = RobotLab::RactorJob.new(
        id: 'abc',
        type: :tool,
        payload: { tool_class: 'MyTool', args: { x: 1 }.freeze }.freeze,
        reply_queue: reply_q
      )
      assert Ractor.shareable?(job)
    end

    def test_ractor_job_error_is_shareable
      err = RobotLab::RactorJobError.new(
        message: 'boom',
        backtrace: ['line 1'].freeze
      )
      assert Ractor.shareable?(err)
    end

    def test_robot_spec_is_shareable
      spec = RobotLab::RobotSpec.new(
        name: 'bot',
        template: nil,
        system_prompt: 'Be helpful.',
        config_hash: { model: 'claude-sonnet-4' }.freeze
      )
      assert Ractor.shareable?(spec)
    end

    def test_ractor_boundary_error_is_subclass_of_error
      assert RobotLab::RactorBoundaryError < RobotLab::Error
    end

    def test_version_is_defined
      refute_nil RobotLab::RactorPool::VERSION
    end
  end
end
