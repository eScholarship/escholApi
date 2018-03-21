require 'base64'
require 'json'
require 'unindent'

###################################################################################################
# For batching
class RecordLoader < GraphQL::Batch::Loader
  def initialize(model)
    @model = model
  end

  def perform(ids)
    @model.where(id: ids).each { |record| fulfill(record.id, record) }
    ids.each { |id| fulfill(id, nil) unless fulfilled?(id) }
  end
end

###################################################################################################
class CountLoader < GraphQL::Batch::Loader
  def initialize(query, field)
    @query = query
    @field = field
  end
  def perform(ids)
    @query.where(Hash[@field, ids]).group_and_count(@field).each { |row|
      fulfill(row[@field], row[:count])
    }
    ids.each { |id| fulfill(id, nil) unless fulfilled?(id) }
  end
end

###################################################################################################
class GroupLoader < GraphQL::Batch::Loader
  def initialize(query, field, limit = nil)
    @query = query
    @field = field
    @limit = limit
  end

  def perform(ids)
    result = Hash.new { |h,k| h[k] = [] }
    @query.where(Hash[@field, ids]).each{ |record|
      if !@limit || result[record[@field]].length < @limit
        result[record[@field]] << record
      end
    }
    result.each { |k,v| fulfill(k,v) }
    ids.each { |id| fulfill(id, nil) unless fulfilled?(id) }
  end
end

###################################################################################################
DateType = GraphQL::ScalarType.define do
  name "Date"
  description %{A date in ISO-8601 format. Example: "2018-03-09"}

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
  description %{A date and time in ISO-8601 format, including timezone.
                Example: "2018-03-09T15:02:42-08:00"
                If you don't specify the time, midnight (server-local) will be used.}.unindent

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

  field :status, !ItemStatusEnum, "Publication status; usually PUBLISHED" do
    resolve -> (obj, args, ctx) { obj.status.upcase }
  end

  field :type, !ItemTypeEnum, "Publication type; usually ARTICLE" do
    resolve -> (obj, args, ctx) {
      obj.genre == "dissertation" ? "ETD" : obj.genre.upcase
    }
  end

  field :published, !types.String, "Date the item was published" do
    resolve -> (obj, args, ctx) { obj.published }
  end

  field :added, !DateType, "Date the item was added to eScholarship" do
    resolve -> (obj, args, ctx) { obj.added }
  end

  field :updated, !DateTimeType, "Date and time the item was last updated on eScholarship" do
    resolve -> (obj, args, ctx) { obj.updated }
  end

  field :permalink, !types.String, "Permanent link to the item on escholarship.org" do
    resolve -> (obj, args, ctx) { "https://escholarship.org/uc/item/#{obj.id.sub(/^qt/,'')}" }
  end

  field :contentType, types.String, "Main content MIME type (e.g. application/pdf)" do
    resolve -> (obj, args, ctx) { obj.content_type }
  end

  field :contentLink, types.String, "Download link for PDF/content file (if applicable)" do
    resolve -> (obj, args, ctx) {
      obj.status == "published" && obj.content_type == "application/pdf" ?
        "https://escholarship.org/content/#{obj.id}/#{obj.id}.pdf" : nil
    }
  end

  field :authors, AuthorsType, "All authors (can be long)" do
    argument :first, types.Int, default_value: 100, prepare: ->(val, ctx) {
      (val.nil? || (val >= 1 && val <= 500)) or return GraphQL::ExecutionError.new("'first' must be in range 1..500")
      return val
    }
    argument :more, types.String
    resolve -> (obj, args, ctx) { AuthorsData.new(args, obj.id) }
  end

  field :units, !types[UnitType], "The series/unit(s) associated with this item" do
    resolve -> (obj, args, ctx) {
      query = UnitItem.where(is_direct: true).order(:item_id, :ordering_of_units).select(:item_id, :unit_id)
      GroupLoader.for(query, :item_id).load(obj.id).then { |unitItems|
        RecordLoader.for(Unit).load_many(unitItems ? unitItems.map { |unitItem| unitItem.unit_id } : [])
      }
    }
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
ItemStatusEnum = GraphQL::EnumType.define do
  name "ItemStatus"
  description "Publication status of an Item (usually PUBLISHED)"
  value("EMBARGOED", "Currently under embargo (omitted from queries)")
  value("EMPTY", "Item was published but has no link or files (omitted from queries)")
  value("PUBLISHED", "Normal published item")
  value("WITHDRAWN", "Item was withdrawn (omitted from queries)")
end

###################################################################################################
ItemTypeEnum = GraphQL::EnumType.define do
  name "ItemType"
  description "Publication type of an Item (often ARTICLE)"
  value("ARTICLE", "Normal article, e.g. a journal article")
  value("CHAPTER", "Chapter within a book/monograph")
  value("ETD", "Electronic thesis/dissertation")
  value("MONOGRAPH", "A book / monograph")
  value("MULTIMEDIA", "Multimedia (e.g. video, audio, etc.)")
  value("NON_TEXTUAL", "Other non-textual work")
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
AuthorsType = GraphQL::ObjectType.define do
  name "Authors"
  description "A list of authors, with paging capability because some items have thousands"
  field :total, !types.Int, "Approximate total items on all pages"
  field :nodes, !types[AuthorType], "Array of the items on this page"
  field :more, types.String, "Opaque cursor string for next page"
end

###################################################################################################
class AuthorsData
  def initialize(args, itemID)
    # If 'more' was specified, decode it and use all the parameters from the original query
    @args = args['more'] ? JSON.parse(Base64.urlsafe_decode64(args['more'])) : args.to_h.clone

    # Record the item ID for querying
    @itemID = itemID
  end

  def total
    CountLoader.for(ItemAuthor, :item_id).load(@itemID)
  end

  def nodes
    query = ItemAuthor.order(:item_id, :ordering)
    @args['lastOrd'] and query = query.where(Sequel.lit("ordering > ?", @args['lastOrd']))
    @nodes ||= GroupLoader.for(query, :item_id, @args['first']).load(@itemID)
  end

  def more
    nodes.then { |arr|
      if arr && arr.length == @args['first']
        Base64.urlsafe_encode64(@args.merge({lastOrd: arr[-1].ordering}).to_json)
      else
        nil
      end
    }
  end
end

###################################################################################################
AuthorType = GraphQL::ObjectType.define do
  name "Author"
  description "A single author (can be a person or organization)"

  field :name, !types.String, "Combined name parts; usually 'lname, fname'" do
    resolve -> (obj, args, ctx) { JSON.parse(obj.attrs)['name'] }
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
    argument :first, types.Int, default_value: 100,
      description: "Number of results to return (values 1..500 are valid)",
      prepare: ->(val, ctx) {
        (val.nil? || (val >= 1 && val <= 500)) or return GraphQL::ExecutionError.new("'first' must be in range 1..500")
        return val
      }
    argument :more, types.String, description: %{Opaque string obtained from the `more` field of a prior result,
                                                 and used to fetch the next set of nodes.
                                                 Do not specify any other arguments with this one; the string already
                                                 encodes the prior set of arguments.}.unindent
    argument :before, DateTimeType, description: "Return only items *before* this date/time (within the `order` ordering)"
    argument :after, DateTimeType, description: "Return only items *after* this date/time (within the `order` ordering)"
    argument :tag, types.String, description: "Subset items with keyword, subject, or discipline matching this tag"
    argument :order, ItemOrderEnum, default_value: "ADDED_DESC",
             description: %{Sets the ordering of results
                            (and affect interpretation of the `before` and `after` arguments)}
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
  use GraphQL::Batch
end
