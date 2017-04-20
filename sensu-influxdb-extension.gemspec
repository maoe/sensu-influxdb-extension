Gem::Specification.new do |spec|
  spec.name = "sensu-influxdb-extension"
  spec.version = "0.0.1"
  spec.authors = ["Johnny Horvi"]

  spec.summary = "InfluxDB extension for Sensu"

  spec.files = `git ls-files -z`.split("\x0").reject do |f|
    f.match(%r{^(test|spec|features)/})
  end

  spec.add_dependency "sensu-extension"

  spec.add_development_dependency "rake"
  spec.add_development_dependency "rspec"
end
