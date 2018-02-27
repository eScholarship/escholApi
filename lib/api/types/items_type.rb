require 'base64'
require 'json'

ItemOrderEnum = GraphQL::EnumType.define do
  name "ItemOrder"
  description "Ordering for item list results"
  value("ADDED_ASC", "Date added to eScholarship, oldest to newest")
  value("ADDED_DESC", "Date added to eScholarship, newest to oldest")
  value("PUBLISHED_ASC", "Date published, oldest to newest")
  value("PUBLISHED_DESC", "Date published, newest to oldest")
  value("UPDATED_ASC", "Date updated in eScholarship, oldest to newest")
  value("UPDATED_DESC", "Date updated in eScholarship, newest to oldest")
end

ItemsType = GraphQL::ObjectType.define do
  name "Items"
  description "A list of items, possibly very long, with paging capability"

  field :total, !types.Int, "Approximate total items on all pages" do
    resolve -> (obj, args, ctx) { obj.total }
  end

  field :nodes, !types[ItemType], "Array of the items on this page" do
    resolve -> (obj, args, ctx) { obj.nodes }
  end

  field :more, types.String, "Opaque cursor string for next page" do
    resolve -> (obj, args, ctx) { obj.more }
  end
end

class ItemsData
  attr_reader :total, :nodes, :more

  def initialize(args)
    query = Item.where(status: 'published')
    @total = query.count
    field = args['order'].sub(/_.*/,'').downcase.to_sym
    ascending = (args['order'] =~ /ASC/)
    query = query.order(ascending ? field : Sequel::desc(field),
                        ascending ? :id   : Sequel::desc(:id))
    if args['more']
      dir = ascending ? '>' : '<'
      more = JSON.parse(Base64.urlsafe_decode64(args['more']))
      query = query.where(Sequel.lit("#{field} #{dir} ? or (#{field} = ? and id #{dir} ?)",
                                     more[1], more[1], more[0]))
    end
    limit = args['first'].to_i
    @nodes = query.limit(limit).all
    if @nodes.length == limit
      lastFields = [ nodes[-1].id, nodes[-1][field].iso8601 ]
      @more = Base64.urlsafe_encode64(lastFields.to_json)
    end
  end
end