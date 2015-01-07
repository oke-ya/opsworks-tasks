class Configure
  def initialize(name)
    @name = name
    @config = {}
  end

  def method_missing(name, args)
    @config[name] = args
  end

  def parse
    instance_eval File.read(Rails.root.join('config', "#{@name}.rb"))
    @config
  end
end
