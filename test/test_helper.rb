# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'ractor_queue'

# Minimal RobotLab stubs so the data-carrier and boundary tests run
# without loading robot_lab (which still ships its own ractor files).
# Once robot_lab removes those files and adds robot_lab-ractor as a
# dependency, replace this block with: require "robot_lab/ractor"
module RobotLab
  class Error < StandardError; end           unless defined?(Error)
  unless defined?(RactorBoundaryError)
    class RactorBoundaryError < Error
    end
  end
  unless defined?(ToolError)
    class ToolError < Error
    end
  end
  # Minimal Hook stub matching the real RobotLab::Hook interface.
  # Used only by unit tests that do not load the full robot_lab gem.
  unless defined?(Hook)
    class Hook
      @namespace = nil
      class << self
        attr_writer :namespace

        def namespace
          return @namespace if @namespace
          return nil if self == Hook
          name.split('::').last
              .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
              .gsub(/([a-z\d])([A-Z])/, '\1_\2')
              .downcase.to_sym
        end

        def inherited(subclass)
          super
          subclass.instance_variable_set(:@namespace, nil)
        end
      end
    end
  end
end

require 'robot_lab/ractor/version'
require 'robot_lab/ractor_job'
require 'robot_lab/ractor_boundary'

require 'minitest/autorun'
require 'minitest/pride'
