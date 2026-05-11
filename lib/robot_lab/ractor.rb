# frozen_string_literal: true

# NOTE: This file intentionally does NOT open module RobotLab::Ractor.
# Defining that module would shadow Ruby's built-in Ractor class for all
# code inside the RobotLab namespace, breaking Ractor.new / Ractor.make_shareable
# calls in RactorWorkerPool, RactorNetworkScheduler, etc.

require "etc"
require "ractor_queue"
require "ractor/wrapper"

require_relative "ractor/version"
require_relative "ractor_job"
require_relative "ractor_boundary"
require_relative "ractor_worker_pool"
require_relative "ractor_memory_proxy"
require_relative "ractor_network_scheduler"

# Extend the RobotLab module with Ractor pool lifecycle methods.
# Once robot_lab removes its own copies and adds robot_lab-ractor as a
# dependency, this becomes the single source of truth for ractor_pool.
module RobotLab
  class << self
    def ractor_pool
      @ractor_pool ||= begin
        size = respond_to?(:config) && config.respond_to?(:ractor_pool_size) \
          ? (config.ractor_pool_size || :auto) : :auto
        RactorWorkerPool.new(size: size)
      end
    end

    def shutdown_ractor_pool
      @ractor_pool&.shutdown
      @ractor_pool = nil
    end
  end
end

if defined?(RobotLab) && RobotLab.respond_to?(:register_extension)
  RobotLab.register_extension(:ractor, :ractor_extension_loaded)
end
