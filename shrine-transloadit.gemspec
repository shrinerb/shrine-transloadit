Gem::Specification.new do |gem|
  gem.name          = "shrine-transloadit"
  gem.version       = "0.4.3"

  gem.required_ruby_version = ">= 2.1"

  gem.summary      = "Provides Transloadit integration for Shrine."
  gem.homepage     = "https://github.com/janko-m/shrine-transloadit"
  gem.authors      = ["Janko Marohnić"]
  gem.email        = ["janko.marohnic@gmail.com"]
  gem.license      = "MIT"

  gem.files        = Dir["README.md", "LICENSE.txt", "lib/**/*.rb", "*.gemspec"]
  gem.require_path = "lib"

  gem.add_dependency "shrine", "~> 2.6"
  gem.add_dependency "transloadit", "~> 2.0"

  gem.add_development_dependency "rake"
  gem.add_development_dependency "minitest"
  gem.add_development_dependency "minitest-hooks"
  gem.add_development_dependency "dotenv"
  gem.add_development_dependency "aws-sdk-s3", "~> 1.2"
  gem.add_development_dependency "sequel"
  gem.add_development_dependency "sqlite3"
end
