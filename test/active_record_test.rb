# frozen_string_literal: true

require "minitest/autorun"
require "export_kit/active_record"
require "sqlite3"

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Schema.define do
  create_table :export_kit_test_users, force: true do |table|
    table.string :email, null: false
    table.string :encrypted_password, null: false
    table.timestamps null: false
  end
end

class ActiveRecordTest < Minitest::Test
  class ExportUser < ActiveRecord::Base
    self.table_name = "export_kit_test_users"
    include ExportKit::ModelSchema

    export_schema do
      allow :email, ->(value) { value.upcase }, :created_at
      omit :encrypted_password, reason: :credential
    end
  end

  class PlainUser < ActiveRecord::Base
    self.table_name = "export_kit_test_users"
  end

  def setup
    PlainUser.delete_all
  end

  def test_explicit_fields_select_only_allowed_data_and_hide_the_internal_cursor
    users = create_users(5)
    sql = []
    subscriber = ->(event) { sql << event.payload[:sql] }
    artifact = nil

    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      table = ExportKit.records(PlainUser.where(id: users.map(&:id)), fields: [:email], batch_size: 2)
      artifact = ExportKit.render(table, format: :json, max_bytes: 10_000).value!
    end

    assert_equal users.map { { "email" => it.email } }, JSON.parse(artifact.file.read)
    selections = sql.select { it.start_with?("SELECT") && it.include?(%("export_kit_test_users")) }
    assert_equal 4, selections.size
    assert(selections.all? { it.include?(%("export_kit_test_users"."id")) && it.include?(%("email")) })
    refute(selections.any? { it.include?("encrypted_password") || it.include?(%("export_kit_test_users".*)) })
  ensure
    artifact&.close!
  end

  def test_schema_policy_rejects_unclassified_and_hidden_fields
    assert_raises(ArgumentError) { ExportKit.records(PlainUser.all, fields: :all) }
    assert_raises(ArgumentError) { ExportKit.records(PlainUser.all, fields: [:imaginary_secret]) }
    assert_raises(ArgumentError) { ExportKit.records(ExportUser.all, fields: [:encrypted_password]) }
    assert_raises(ArgumentError) { ExportKit.records(ExportUser.all, fields: [:id]) }
    assert_raises(ArgumentError) { ExportUser.validate_export_schema! }
  end

  def test_complete_schema_classification_is_opt_in
    model = Class.new(PlainUser) do
      include ExportKit::ModelSchema
    end
    columns = model.column_names
    schema = model.export_schema do
      allow :email
      deny(*(columns - ["email"]), reason: :not_needed)
    end

    assert model.validate_export_schema!
    assert_equal schema.denied, schema.omit
    assert_equal ["email"], schema.allowed
    assert_raises(ArgumentError) do
      ExportKit::ModelSchema::DefinitionBuilder.new.omit(:secret, reason: " ")
    end
  end

  def test_computed_fields_and_formatters_use_the_same_bounded_table_pipeline
    user = create_user
    serializer = ExportKit::ModelSerializer.new
    serializer.category(:account) do
      records :accounts, model: ExportUser, fields: [:email], scope: ->(id) { ExportUser.where(id:) } do
        computed :label, sql: ->(_) { "'safe-label'" }, presenter: ->(value) { value.upcase }
      end
    end
    set = serializer.fetch(:account).record_sets.first

    expected = [{ "email" => user.email.upcase, "label" => "SAFE-LABEL" }]
    assert_equal expected, set.each_row(input: user.id).to_a
    artifact = ExportKit.render(set.table(input: user.id), format: :json, max_bytes: 4096).value!
    assert_equal expected, JSON.parse(artifact.file.read)
  ensure
    artifact&.close!
  end

  def test_formatter_failure_has_a_safe_location_without_the_rejected_value
    users = create_users(3)
    serializer = ExportKit::ModelSerializer.new
    serializer.category(:account) do
      records :accounts, model: PlainUser, fields: [:email], scope: ->(_) { PlainUser.where(id: users.map(&:id)) } do
        format(:email) do |value|
          raise ArgumentError, "CANARY-#{value}" if value == users.last.email

          value
        end
      end
    end

    result = ExportKit.render(serializer.fetch(:account).record_sets.first.table(batch_size: 1),
                              format: :csv, max_bytes: 4096)
    assert_equal ExportKit::Render::RENDER_FAILED, result.error
    assert_equal({ record_set: "accounts", row: 3, column: "email" }, result.error_details)
    refute_includes result.inspect, "CANARY"
    refute_includes result.inspect, users.last.email
  end

  def test_unordered_limit_is_respected_and_explicit_order_is_rejected
    users = create_users(4)
    table = ExportKit.records(PlainUser.where(id: users.map(&:id)).limit(3), fields: [:email], batch_size: 2)
    artifact = ExportKit.render(table, format: :json, max_bytes: 4096).value!
    assert_equal users.first(3).map { { "email" => it.email } }, JSON.parse(artifact.file.read)

    ordered = ExportKit.records(PlainUser.order(id: :desc).limit(3), fields: [:email])
    assert_raises(ArgumentError) { ExportKit.render(ordered, format: :json, max_bytes: 4096) }
  ensure
    artifact&.close!
  end

  private

  def create_users(count)
    Array.new(count) { create_user }
  end

  def create_user
    sequence = PlainUser.maximum(:id).to_i + 1
    PlainUser.create!(email: "user#{sequence}@example.test", encrypted_password: "not-exported")
  end
end
