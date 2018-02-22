ItemType = GraphQL::ObjectType.define do
  name "Item"
  description "An item"

  field :id, !types.ID, "eScholarship ARK identifier" do
    resolve -> (obj, args, ctx) { "ark:/13030/#{obj.id}" }
  end
  field :title, !types.String, "Title of the item (may include embedded HTML formatting tags)"
end
