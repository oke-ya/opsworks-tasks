begin
  require 'rails_erd'
  require 'rails_erd/domain/attribute'
  class << RailsERD::Domain::Attribute
    def from_model(domain, model)
      model.columns.collect { |column| new(domain, model, column) }
    end
  end
rescue LoadError
end
