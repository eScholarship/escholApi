require 'base64'
require 'json'

###################################################################################################
DateType = GraphQL::ScalarType.define do
  name "Date"
  description "A date in ISO-8601 format"

  coerce_input ->(value, ctx) do
    begin
      Date.iso8601(value)
    rescue ArgumentError
      raise GraphQL::CoercionError, "cannot coerce `#{value.inspect}` to Date; must be ISO-8601 format"
    end
  end

  coerce_result ->(value, ctx) { value.iso8601 }
end

###################################################################################################
DateTimeType = GraphQL::ScalarType.define do
  name "DateTime"
  description "A date and time in ISO-8601 format, including timezone"

  coerce_input ->(value, ctx) do
    begin
      # Normalize timezone to localtime
      Time.iso8601(value).localtime.to_datetime
    rescue ArgumentError
      begin
        # Synthesize timezone
        (Date.iso8601(value).to_time - Time.now.utc_offset).to_datetime
      rescue ArgumentError
        raise GraphQL::CoercionError, "cannot coerce `#{value.inspect}` to DateTime; must be ISO-8601 format"
      end
    end
  end

  coerce_result ->(value, ctx) { value.iso8601 }
end

###################################################################################################
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

  field :added, !DateType, "Date the item was added to eScholarship" do
    resolve -> (obj, args, ctx) { obj.added }
  end

  field :updated, !DateTimeType, "Date and time the item was last updated on eScholarship" do
    resolve -> (obj, args, ctx) { obj.updated }
  end

  field :tags, types[types.String], "Unified disciplines, keywords, and subjects" do
    resolve -> (obj, args, ctx) {
      attrs = obj.attrs ? JSON.parse(obj.attrs) : {}
      out = (attrs['disciplines'] || []) +
            (attrs['keywords'] || []) +
            (attrs['subjects'] || [])
      out.empty? ? nil : out
    }
  end

  # TODO: many more item fields in the schema
end

###################################################################################################
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

###################################################################################################
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

###################################################################################################
class ItemsData
  attr_reader :total, :nodes, :more

  def initialize(args, unitID = nil)
    query = Item.where(status: 'published')

    # If 'more' was specified, decode it and use all the parameters from the original query
    args['more'] and args = JSON.parse(Base64.urlsafe_decode64(args['more']))

    # If this is a unit query, restrict to items within that unit.
    if unitID
      query = query.where(Sequel.lit("id in (select item_id from unit_items where unit_id = ?)", unitID))
    end

    # Let's get the ordering correct -- using the right field, and either ascending or descending
    field = args['order'].sub(/_.*/,'').downcase.to_sym
    ascending = (args['order'] =~ /ASC/)
    query = query.order(ascending ? field : Sequel::desc(field),
                        ascending ? :id   : Sequel::desc(:id))

    # If this is a 'more' query, add extra constraints so we get the next page (that is,
    # starting just after the end of the last page)
    if args['lastID']
      dir = ascending ? '>' : '<'
      query = query.where(Sequel.lit("#{field} #{dir} ? or (#{field} = ? and id #{dir} ?)",
                                     args['lastDate'], args['lastDate'], args['lastID']))
    end

    # Apply limits as specified
    args['before'] and query = query.where(Sequel.lit("#{field} < ?", args['before']))
    args['after']  and query = query.where(Sequel.lit("#{field} > ?", args['after']))

    # Matching on tags if specified
    if args['tag']
      query = query.where(Sequel.lit(%{
        json_search(attrs, 'all', ?, null, '$.disciplines') is not null or
        json_search(attrs, 'all', ?, null, '$.keywords') is not null or
        json_search(attrs, 'all', ?, null, '$.subjects') is not null
      }, args['tag'], args['tag'], args['tag']))
    end

    # Record the total matching
    @total = query.count

    # Okay, go get one page of items
    limit = args['first'].to_i
    @nodes = query.limit(limit).all

    # If there might be more in the list, encode all the parameters needed to query for
    # the next page.
    if @nodes.length == limit
      more = args.to_h.clone
      more['lastID']   = nodes[-1].id
      more['lastDate'] = nodes[-1][field].iso8601
      @more = Base64.urlsafe_encode64(more.to_json)
    end
  end
end

###################################################################################################
UnitType = GraphQL::ObjectType.define do
  name "Unit"
  description "A campus, department, series, or other organized unit within eScholarship"

  field :id, !types.ID, "Short unit identifier, e.g. 'lbnl_rw'"

  field :name, !types.String, "Human-readable name of the unit"

  field :items, ItemsType, "Query items in the unit (incl. children)" do
    argument :first, types.Int, default_value: 100, prepare: ->(val, ctx) {
      (val.nil? || (val >= 1 && val <= 500)) or return GraphQL::ExecutionError.new("'first' must be in range 1..500")
      return val
    }
    argument :more, types.String
    argument :before, DateTimeType
    argument :after, DateTimeType
    argument :tag, types.String
    argument :order, ItemOrderEnum, default_value: "ADDED_DESC"
    resolve -> (obj, args, ctx) { ItemsData.new(args, obj.id) }
  end


  # TODO: many more fields in the schema
end

###################################################################################################
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
    argument :more, types.String, description: "more"
    argument :before, DateTimeType
    argument :after, DateTimeType
    argument :tag, types.String
    argument :order, ItemOrderEnum, default_value: "ADDED_DESC"
    resolve -> (obj, args, ctx) { ItemsData.new(args) }
  end

  field :unit, UnitType, "Get a unit given its identifier" do
    argument :id, !types.ID
    resolve -> (obj, args, ctx) { Unit[args["id"]] }
  end
end

###################################################################################################
Schema = GraphQL::Schema.define do
  query QueryType
end
