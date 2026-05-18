# frozen_string_literal: true

require 'test_helper'

module RobotLab
  class RactorPoolVersionTest < Minitest::Test
    def test_version_is_defined
      refute_nil RobotLab::RactorPool::VERSION
    end
  end
end
