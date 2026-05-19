# test/test.rb - Ruby fixture for dev_ruby integration tests.
#
# Defines singleton methods on AOProcess that follow the AOProcess.<func>(process, message, opts)
# calling convention used by the HyperBEAM Ruby device.

module AOProcess

  def self.hello(process, message, opts)
    name = message["name"] || "world"
    {"body" => "Hello, " + name + "!"}
  end

  def self.add(process, message, opts)
    a = message["a"] || 0
    b = message["b"] || 0
    {"result" => a + b}
  end

  def self.greet(process, message, opts)
    name = message["name"] || "world"
    greeting = message["greeting"] || "Hello"
    {"body" => greeting + ", " + name + "!"}
  end

  def self.compute(process, message, opts)
    # Counter: increments process["count"] on each call
    process["count"] ||= 0
    process["count"] += 1
    process["results"] = {"output" => {"body" => process["count"]}}
    process
  end

  def self.identity(process, message, opts)
    message["value"]
  end

  def self.echo(process, message, opts)
    message
  end

  def self.count_chars(process, message, opts)
    text = message["text"] || ""
    {"length" => text.length, "text" => text}
  end

end
