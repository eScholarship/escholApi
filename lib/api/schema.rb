require_relative 'types/item_type'
require_relative 'types/items_type'

QueryType = GraphQL::ObjectType.define do
  name "Query"
  description "The eScholarship API"

  field :item, ItemType, "Get item's info given its identifier" do
    argument :id, !types.ID
    resolve -> (obj, args, ctx) { Item[args["id"]] }
  end

  field :items, ItemsType, "Query a list of all items" do
    argument :first, types.Int, default_value: 100, prepare: ->(val, ctx) {
      (val.nil? || (val >= 1 && val <= 500)) or return GraphQL::ExecutionError.new("'first' must be in range 1..500")
      return val
    }
    argument :more, types.String
    argument :order, ItemOrderEnum, default_value: "ADDED_DESC"
    resolve -> (obj, args, ctx) { ItemsData.new(args) }
  end
end

Schema = GraphQL::Schema.define do
  query QueryType
end
