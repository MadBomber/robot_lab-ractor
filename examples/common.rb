# frozen_string_literal: true

require "logger"

$LOAD_PATH.unshift File.expand_path("../../robot_lab/lib", __dir__)
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "robot_lab"
require "robot_lab/ractor"

# Unbuffered stdout so Ractor-generated output interleaves correctly with
# main-thread headers when viewed in a terminal or redirected to a pipe.
$stdout.sync = true

# Fallback for when direnv has not activated examples/.envrc
ENV["ROBOT_LAB_TEMPLATE_PATH"] ||= File.join(__dir__, "prompts")

RubyLLM.configure do |c|
  c.logger                 = Logger.new(File::NULL)
  c.default_model          = "claude-haiku-4-5-20251001"
  c.anthropic_api_key      = ENV["ANTHROPIC_API_KEY"]
  c.openai_api_key         = ENV["OPENAI_API_KEY"]
  c.openai_organization_id = ENV["OPENAI_ORGANIZATION_ID"]
  c.openai_project_id      = ENV["OPENAI_PROJECT_ID"]
end

RobotLab.configure do |c|
  c.logger = Logger.new(File::NULL)
end

# ── Output Helpers ─────────────────────────────────────────────────────────────

module ExOut
  WIDTH = 62
  RESET = "\e[0m"
  BOLD  = "\e[1m"
  DIM   = "\e[2m"
  CYAN  = "\e[36m"
end

# Prints a bold top-level banner. Extracts the example number from $0
# automatically so callers only supply the title.
def banner(title)
  num   = File.basename($0, ".rb")[/^\d+/]&.to_i
  label = num ? "Example #{num}: #{title}" : title
  puts "#{ExOut::BOLD}#{"=" * ExOut::WIDTH}#{ExOut::RESET}"
  puts "#{ExOut::BOLD} #{label}#{ExOut::RESET}"
  puts "#{ExOut::BOLD}#{"=" * ExOut::WIDTH}#{ExOut::RESET}"
  puts
end

# Prints a named section divider.
def section(title)
  puts
  tail = "─" * [ExOut::WIDTH - title.length - 4, 2].max
  puts "#{ExOut::BOLD}#{ExOut::CYAN}── #{title} #{tail}#{ExOut::RESET}"
  puts
end

# Prints a plain horizontal rule.
def hr
  puts "#{ExOut::DIM}#{"─" * ExOut::WIDTH}#{ExOut::RESET}"
end

# Prints a Rouge-highlighted Ruby snippet with a framed border.
def show_code(ruby_string, label: "ruby")
  require "rouge"
  w      = ExOut::WIDTH - 2
  border = "#{ExOut::DIM}  #{"─" * w}#{ExOut::RESET}"
  output = Rouge::Formatters::Terminal256.new
             .format(Rouge::Lexers::Ruby.new.lex(ruby_string))
  output += "\n" unless output.end_with?("\n")
  puts
  puts "#{ExOut::DIM}  #{label}#{ExOut::RESET}"
  puts border
  output.each_line { |l| print "  #{l}" }
  puts border
  puts
end
