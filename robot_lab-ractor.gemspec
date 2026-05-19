# frozen_string_literal: true

require_relative 'lib/robot_lab/ractor/version'

Gem::Specification.new do |spec|
  spec.name     = 'robot_lab-ractor'
  spec.version  = RobotLab::RactorPool::VERSION
  spec.authors  = ['Dewayne VanHoozer']
  spec.email    = ['dvanhoozer@gmail.com']

  spec.summary     = 'Ractor-based parallel tool execution for RobotLab agents'
  spec.description = 'Provides RobotLab::RactorWorkerPool — a pool of Ruby Ractor workers ' \
                     'for executing CPU-bound, Ractor-safe tools in parallel. Includes ' \
                     'RactorBoundary (deep-freeze utility for crossing Ractor boundaries), ' \
                     'RactorJob/RactorJobError/RobotSpec (frozen data carriers), ' \
                     'RactorMemoryProxy (shared Memory access from inside Ractors), and ' \
                     'RactorNetworkScheduler (dependency-ordered pipeline across Ractors).'
  spec.homepage = 'https://github.com/MadBomber/robot_lab-ractor'
  spec.license  = 'MIT'

  spec.required_ruby_version = '>= 3.2.0'

  spec.metadata['homepage_uri']    = spec.homepage
  spec.metadata['source_code_uri'] = spec.homepage
  spec.metadata['changelog_uri']   = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata['rubygems_mfa_required'] = 'true'

  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore test/ sig/])
    end
  end

  spec.require_paths = ['lib']

  spec.add_dependency 'ractor_queue'
  spec.add_dependency 'ractor-wrapper'
  spec.add_dependency 'robot_lab', '~> 0.2.0'
end
