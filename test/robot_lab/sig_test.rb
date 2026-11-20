# frozen_string_literal: true

require 'test_helper'

module RobotLab
  # Regression: sig/ once declared `module RobotLab::Ractor`, the very module
  # this gem must never define (it would shadow Ruby's built-in Ractor).
  class SigTest < Minitest::Test
    SIG = File.read(File.expand_path('../../sig/robot_lab/ractor.rbs', __dir__))

    def test_sig_declares_ractor_pool_version
      assert_match(/module RactorPool\s+VERSION: String/, SIG)
    end

    def test_sig_does_not_declare_a_robot_lab_ractor_module
      refute_match(/^\s*module Ractor\s*$/, SIG)
    end

    def test_robot_lab_ractor_module_is_not_defined
      refute RobotLab.const_defined?(:Ractor, false)
    end
  end
end
