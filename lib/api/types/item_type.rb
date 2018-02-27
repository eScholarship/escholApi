ItemType = GraphQL::ObjectType.define do
  name "Item"
  description "An item"

  field :id, !types.ID, "eScholarship ARK identifier" do
    resolve -> (obj, args, ctx) { "ark:/13030/#{obj.id}" }
  end
  field :title, !types.String, "Title of the item (may include embedded HTML formatting tags)"
  field :published, !types.String, "Date the item was published" do
    resolve -> (obj, args, ctx) { obj.published }
  end
  field :added, !types.String, "Date the item was added to eScholarship" do
    resolve -> (obj, args, ctx) { obj.added }
  end
end
