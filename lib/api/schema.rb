require_relative 'types/item_type'

QueryType = GraphQL::ObjectType.define do
  name "Query"
  description "The eScholarship API"

  field :item do
    type ItemType
    argument :id, !types.ID
    resolve -> (obj, args, ctx) {
      Item[args["id"]]
    }
  end
end

Schema = GraphQL::Schema.define do
  query QueryType
end
