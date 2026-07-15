require_relative "lib/veltrunode/version"

Gem::Specification.new do |spec|
  spec.name          = "veltrunode"
  spec.version       = Veltrunode::VERSION
  spec.authors       = ["hirontan"]
  spec.email         = ["[EMAIL_ADDRESS]"]

  spec.summary       = "Ruby-first toolkit for scheduled and file-oriented AWS Lambda applications."
  spec.homepage      = "https://github.com/hirontan/veltrunode"
  spec.license       = "Apache-2.0"
  spec.required_ruby_version = ">= 3.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage

  spec.files = Dir["lib/**/*.rb", "exe/*", "LICENSE", "README.md"]
  spec.bindir        = "exe"
  spec.executables   = ["veltrunode"]
  spec.require_paths = ["lib"]

  spec.add_dependency "thor", "~> 1.2"
end
