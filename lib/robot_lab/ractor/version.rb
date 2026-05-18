# frozen_string_literal: true

module RobotLab
  # RactorPool (not Ractor) avoids shadowing Ruby's built-in Ractor class
  # for all code within the RobotLab namespace.
  module RactorPool
    VERSION = '0.1.0'
  end
end
