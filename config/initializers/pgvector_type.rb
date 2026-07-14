# frozen_string_literal: true

require "active_record/connection_adapters/postgresql_adapter"

ActiveSupport.on_load(:active_record) do
  adapter = ActiveRecord::ConnectionAdapters::PostgreSQLAdapter
  adapter::NATIVE_DATABASE_TYPES[:vector] = { name: "vector" }

  next if adapter.respond_to?(:wizwiki_pgvector_type_registered?)

  adapter.singleton_class.prepend(Module.new do
    def initialize_type_map(map)
      super
      map.register_type "vector", ActiveRecord::ConnectionAdapters::PostgreSQL::OID::SpecializedString.new(:vector)
    end
  end)

  adapter.define_singleton_method(:wizwiki_pgvector_type_registered?) { true }

  table_definition = ActiveRecord::ConnectionAdapters::PostgreSQL::TableDefinition
  unless table_definition.method_defined?(:vector)
    table_definition.define_method(:vector) do |*names, **options|
      names.each { |name| column(name, :vector, **options) }
    end
  end
end
