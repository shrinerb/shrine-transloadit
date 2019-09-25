Gem::Specification.new do |gem|
  gem.name          = "shrine-transloadit"
  gem.version       = "1.0.0"

  gem.required_ruby_version = ">= 2.2"

  gem.summary      = "Provides Transloadit integration for Shrine."
  gem.homepage     = "https://github.com/shrinerb/shrine-transloadit"
  gem.authors      = ["Janko Marohnić"]
  gem.email        = ["janko.marohnic@gmail.com"]
  gem.license      = "MIT"

  gem.files        = Dir["README.md", "LICENSE.txt", "lib/**/*.rb", "*.gemspec"]
  gem.require_path = "lib"

  gem.add_dependency "shrine", ">= 3.0.0.beta3", "< 4"
  gem.add_dependency "transloadit", "~> 2.0"

  gem.add_development_dependency "rake"
  gem.add_development_dependency "minitest"
  gem.add_development_dependency "aws-sdk-s3", "~> 1.14"
  gem.add_development_dependency "shrine-url"
  gem.add_development_dependency "dry-monitor"
end
