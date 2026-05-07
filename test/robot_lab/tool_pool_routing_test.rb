# frozen_string_literal: true

# Integration test: requires the full robot_lab gem + this extension.
# Run separately from the unit tests (which use stubs) because they need
# the real RobotLab::Tool, RobotLab::RactorWorkerPool, etc.
begin
  require "robot_lab"
  require "robot_lab/ractor"
rescue LoadError => e
  warn "Skipping tool_pool_routing_test: #{e.message}"
  return
end

require "minitest/autorun"
require "minitest/pride"

# Must be top-level so Ractors can resolve it via Object.const_get.
class PoolRoutingTestTool < RobotLab::Tool
  description "Multiplies by 3"
  param :n, type: "number", desc: "Input"
  ractor_safe true
  def execute(n:) = n * 3
end

class RobotLab::ToolPoolRoutingTest < Minitest::Test
  def test_ractor_safe_tool_call_routes_through_pool
    result = PoolRoutingTestTool.new.call({ "n" => 7 })
    assert_equal 21, result
  ensure
    RobotLab.shutdown_ractor_pool if RobotLab.respond_to?(:shutdown_ractor_pool)
  end

  def test_non_ractor_safe_tool_call_runs_inline
    klass = Class.new(RobotLab::Tool) do
      description "Inline tool"
      param :x, type: "string", desc: "Input"
      def execute(x:) = "inline:#{x}"
    end
    result = klass.new.call({ "x" => "hello" })
    assert_equal "inline:hello", result
  end
end
