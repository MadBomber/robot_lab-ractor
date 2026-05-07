# frozen_string_literal: true

require "test_helper"

class RobotLab::RactorPoolVersionTest < Minitest::Test
  def test_version_is_defined
    refute_nil RobotLab::RactorPool::VERSION
  end
end
