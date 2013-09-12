# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'traject/version'

Gem::Specification.new do |spec|
  spec.name          = "traject"
  spec.version       = Traject::VERSION
  spec.authors       = ["Jonathan Rochkind"]
  spec.email         = ["none@nowhere.org"]
  spec.summary       = %q{Index MARC to Solr; or generally process source records to hash-like structures}
  spec.homepage      = "http://github.com/jrochkind/traject"
  spec.license       = "MIT"

  spec.files         = `git ls-files`.split($/)
  spec.executables   = ["traject"]
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ["lib"]


  spec.add_dependency "marc", ">= 0.7.1"
  spec.add_dependency "marc-marc4j", ">=0.1.1"
  spec.add_dependency "hashie", ">= 2.0.5", "< 2.1" # used for Indexer#settings
  spec.add_dependency "slop", ">= 3.4.5", "< 4.0"   # command line parsing
  spec.add_dependency "yell" # logging

  spec.add_development_dependency "bundler", "~> 1.3"
  spec.add_development_dependency "rake"
  spec.add_development_dependency "minitest"
end
