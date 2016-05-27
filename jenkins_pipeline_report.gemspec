# coding: utf-8
require_relative "lib/jenkins_pipeline_report/version"

Gem::Specification.new do |spec|
  spec.name = "jenkins_pipeline_report"
  spec.homepage = "https://github.com/chef/jenkins_pipeline_report"
  spec.version = JenkinsPipelineReport::VERSION
  spec.summary = %q{Produce reports from Jenkins by combining jobs together in pipelines}
  spec.description = spec.summary
  spec.author = "John Keiser"
  spec.email = "jkeiser@chef.io"
  spec.platform = Gem::Platform::RUBY
  spec.license = "Apache-2.0"

  # Chef does not support ruby 2.0 or below
  spec.required_ruby_version = ">= 2.1.0"

  spec.add_dependency "jenkins_api_client"
  spec.add_dependency "psych"

  spec.add_development_dependency "github_changelog_generator"
  spec.add_development_dependency "chefstyle"
  spec.add_development_dependency "rake"
  spec.add_development_dependency "rspec"
  spec.add_development_dependency "bundler"
  # useful things to have while developing:
  spec.add_development_dependency "pry"

  spec.extra_rdoc_files = %w{CHANGELOG.md README.md}
  spec.files = %w{Rakefile Gemfile Gemfile.lock} + spec.extra_rdoc_files + Dir.glob("{distro,lib,tasks,spec,exe}/**/*", File::FNM_DOTMATCH).reject { |f| File.directory?(f) }
  spec.bindir = "exe"
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Prevent pushing this gem to RubyGems.org by setting 'allowed_push_host', or
  # delete this section to allow pushing this gem to any host.
  # if spec.respond_to?(:metadata)
  #   spec.metadata["allowed_push_host"] = "TODO: Set to \"http://mygemserver.com\""
  # else
  #   raise "RubyGems 2.0 or newer is required to protect against public gem pushes."
  # end
end
