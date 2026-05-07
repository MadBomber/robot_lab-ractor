# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "ractor_queue"

# Minimal RobotLab stubs so the data-carrier and boundary tests run
# without loading robot_lab (which still ships its own ractor files).
# Once robot_lab removes those files and adds robot_lab-ractor as a
# dependency, replace this block with: require "robot_lab/ractor"
module RobotLab
  Error               = StandardError        unless defined?(Error)
  RactorBoundaryError = Class.new(Error)     unless defined?(RactorBoundaryError)
  ToolError           = Class.new(Error)     unless defined?(ToolError)
end

require "robot_lab/ractor/version"
require "robot_lab/ractor_job"
require "robot_lab/ractor_boundary"

require "minitest/autorun"
require "minitest/pride"
