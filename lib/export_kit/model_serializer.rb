# frozen_string_literal: true

module ExportKit
  # Generic DSL for selecting model rows and a subset of fields allowed by `export_schema`.
  # It knows Active Record, but not a concrete export, document shape or output format.
  # Non-model rows deliberately bypass this class and are created by an export presenter.
  class ModelSerializer
    Field = Data.define(:key, :label_key)

    Category = Data.define(:category, :version, :record_sets, :omitted_tables, :omission_reason) do
      def included? = record_sets.any?
    end

    RecordSet = Data.define(
      :name, :model, :scope, :fields, :expressions, :export_fields, :field_presenters, :policy
    ) do
      def output_keys = export_fields.map(&:key)

      def selections(subject)
        table = model.arel_table
        fields.map { table[it] } + expressions.values.map { Arel.sql(it.call(subject)) }
      end

      def page(subject, after:, limit:)
        id = model.arel_table[model.primary_key]
        relation = scope.call(subject)
        relation = relation.where(id.gt(after)) unless after.nil?
        relation.reorder(id).limit(limit)
      end

      def each_row(input: nil, batch_size: 500, &block)
        return enum_for(__method__, input:, batch_size:) unless block

        ModelRows.new(record_set: self, input:, batch_size:).each(&block)
      end

      def table(input: nil, labels: {}, batch_size: 500)
        Table.new(columns: output_keys, labels:, rows: ->(&emit) { each_row(input:, batch_size:, &emit) })
      end

      def time_of_day_fields
        fields.select { model.type_for_attribute(it).type == :time }
      end

      def present(row, input:)
        row.to_h do |key, value|
          formatter = field_presenters[key]
          [key, formatter ? present_field(key, formatter, value, input) : value]
        end
      end

      private

      def present_field(key, formatter, value, input)
        present_value(formatter, value, input)
      rescue ArgumentError, TypeError, EncodingError
        raise Renderers::InvalidDocument.new(error_details: { record_set: name, column: key })
      end

      def present_value(formatter, value, input)
        formatter.arity == 1 ? formatter.call(value) : formatter.call(value, input)
      end
    end

    # Read-only table index derived from the model schemas used by this serializer.
    class ModelSchemas
      def initialize(serializer:)
        @schemas = serializer.all.flat_map(&:record_sets).each_with_object({}) do |record_set, index|
          table_name = record_set.model.table_name
          existing = index[table_name]
          if existing && existing != record_set.policy
            raise ArgumentError, "Conflicting export schemas for #{table_name}"
          end

          index[table_name] = record_set.policy
        end.freeze
        freeze
      end

      def all = schemas
      def each(&) = schemas.each(&)
      def fetch(table_name) = schemas.fetch(table_name.to_s)
      def key?(table_name) = schemas.key?(table_name.to_s)

      private

      attr_reader :schemas
    end

    def initialize(record_set_builder: RecordSetBuilder)
      @record_set_builder = record_set_builder
      @categories = {}
    end

    def category(key, version: 1, &definition)
      key = normalize(key)
      raise ArgumentError, "Export category already registered: #{key}" if categories.key?(key)

      categories[key] = CategoryBuilder.new(key, version:, record_set_builder:, &definition).build
    end

    def exclude(key, reason:)
      key = normalize(key)
      raise ArgumentError, "Export category already registered: #{key}" if categories.key?(key)

      categories[key] = Category.new(
        category: key, version: 1, record_sets: [].freeze, omitted_tables: {}.freeze,
        omission_reason: reason
      )
    end

    def all = categories.values.freeze
    def each(&) = categories.each_value(&)
    def fetch(key) = categories.fetch(normalize(key))

    def freeze
      categories.freeze
      super
    end

    private

    attr_reader :categories, :record_set_builder

    def normalize(key)
      key.to_s.tap do |value|
        raise ArgumentError, "Invalid export category: #{value.inspect}" unless value.match?(/\A[a-z][a-z0-9_]*\z/)
      end
    end

    # DSL for one category and its model-backed record sets.
    class CategoryBuilder
      def initialize(category, version:, record_set_builder:, &definition)
        @record_set_builder = record_set_builder
        @category = category.to_s
        @version = version
        @record_sets = []
        @omitted_tables = {}
        instance_eval(&definition)
      end

      def records(name, model:, scope:, fields:, schema: nil, &definition)
        record_sets << record_set_builder.new(name, model:, scope:, fields:, schema:, &definition).build
      end

      def omit_table(table_name, reason:)
        omitted_tables[table_name.to_s] = reason
      end

      def build
        Category.new(category:, version:, record_sets: record_sets.freeze,
                     omitted_tables: omitted_tables.freeze, omission_reason: nil)
      end

      private

      attr_reader :category, :omitted_tables, :record_sets, :version, :record_set_builder
    end

    # DSL for selecting model fields, SQL expressions and per-export formatter overrides.
    class RecordSetBuilder
      def initialize(name, model:, scope:, fields:, schema:, &definition)
        @name = name.to_s
        @model = model
        @scope = scope
        @configured_fields, inline_formatters = parse_fields(fields)
        @policy = schema || (model.export_schema if model.respond_to?(:export_schema))

        @expressions = {}
        @label_keys = {}
        @presenters = inline_formatters
        instance_eval(&definition) if definition
      end

      def computed(key, sql:, label: key, presenter: nil)
        key = key.to_s
        raise ArgumentError, "computed SQL must be callable" unless sql.respond_to?(:call)
        raise ArgumentError, "computed fields must be unique" if expressions.key?(key)

        expressions[key] = sql
        label_keys[key] = label.to_s
        presenters[key] = presenter if presenter
      end

      def format(key, formatter = nil, &block)
        key = key.to_s
        callable = formatter || block
        raise ArgumentError, "#{key} formatter must be callable" unless callable.respond_to?(:call)

        presenters[key] = callable
      end

      def build
        fields = chosen_fields.freeze
        validate_presenters!(fields)
        RecordSet.new(**record_set_attributes(fields))
      end

      private

      attr_reader :configured_fields, :expressions, :label_keys, :model, :name, :policy, :presenters, :scope

      def chosen_fields
        allowed = allowed_fields
        chosen = configured_fields == :all ? allowed : Array(configured_fields).map(&:to_s)
        raise ArgumentError, "#{name} reads a field outside the export schema" unless (chosen - allowed).empty?
        if chosen.uniq != chosen || chosen.intersect?(expressions.keys)
          raise ArgumentError,
                "export fields must be unique"
        end

        chosen
      end

      def allowed_fields
        return policy.allowed if policy
        raise ArgumentError, "fields: :all requires an export schema" if configured_fields == :all

        model.column_names
      end

      def registered_fields(keys)
        labels = keys.index_with { it }.merge(label_keys)
        keys.map { Field.new(key: it, label_key: labels.fetch(it)) }
      end

      def field_presenters_for(fields)
        defaults = policy ? policy.formatters.slice(*fields) : {}
        defaults.merge(presenters).freeze
      end

      def record_set_attributes(fields)
        {
          name:, model:, scope:, fields:, expressions: expressions.freeze,
          export_fields: registered_fields(fields + expressions.keys).freeze,
          field_presenters: field_presenters_for(fields), policy:
        }
      end

      def validate_presenters!(fields)
        unknown = presenters.keys - fields - expressions.keys
        raise ArgumentError, "#{name} formats a field it does not export" if unknown.any?
      end

      def parse_fields(declarations)
        return [:all, {}] if declarations == :all

        items = Array(declarations).dup
        fields = []
        formatters = {}
        until items.empty?
          key = items.shift
          unless key.is_a?(String) || key.is_a?(Symbol)
            raise ArgumentError, "An export field must be a String or Symbol"
          end

          key = key.to_s
          fields << key
          formatters[key] = items.shift if items.first.respond_to?(:call)
        end
        [fields, formatters]
      end
    end
  end
end
