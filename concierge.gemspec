require_relative "lib/concierge/version"

Gem::Specification.new do |spec|
  spec.name        = "concierge"
  spec.version     = Concierge::VERSION
  spec.authors     = [ "Bruno Bornsztein" ]
  spec.email       = [ "bruno.bornsztein@gmail.com" ]
  spec.homepage    = "https://github.com/bruno/concierge"
  spec.summary     = "Per-account AI customer success manager for Rails, built on RubyLLM."
  spec.description = "Concierge is a mountable Rails engine that gives every account a " \
                     "durable, always-on agentic customer success manager. The host app " \
                     "declares what an account is, what the app does, and what the agent " \
                     "may touch; Concierge supplies the runtime, memory, channels, and " \
                     "scheduling."
  spec.license     = "MIT"

  spec.required_ruby_version = ">= 3.1.3"

  spec.metadata["homepage_uri"]    = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"]   = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{app,config,db,lib}/**/*", "MIT-LICENSE", "Rakefile", "README.md"]
  end

  spec.add_dependency "rails", ">= 7.1"
  spec.add_dependency "ruby_llm", ">= 1.14"
  spec.add_dependency "fugit", ">= 1.9"
end
