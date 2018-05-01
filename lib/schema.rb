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

  coerce_result ->(value, ctx) { (value.instance_of?(Date) ? value : Date.iso8601(value)).iso8601 }
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

  field :type, !ItemTypeEnum, "Publication type; majority are ARTICLE" do
    resolve -> (obj, args, ctx) {
      obj.genre == "dissertation" ? "ETD" : obj.genre.upcase.gsub('-','_')
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
        "https://cloudfront.escholarship.org/dist/prd/content/#{obj.id}/#{obj.id}.pdf" : nil
    }
  end

  field :authors, AuthorsType, "All authors (can be long)" do
    argument :first, types.Int, default_value: 100, prepare: ->(val, ctx) {
      (val.nil? || (val >= 1 && val <= 500)) or return GraphQL::ExecutionError.new("'first' must be in range 1..500")
      return val
    }
    argument :more, types.String
    resolve -> (obj, args, ctx) {
      data = AuthorsData.new(args, obj.id)
      data.nodes.then { |nodes|
        nodes && !nodes.empty? ? data : nil
      }
    }
  end

  field :abstract, types.String, "Abstract (may include embedded HTML formatting tags)" do
    resolve -> (obj, args, ctx) {
      (obj.attrs ? JSON.parse(obj.attrs) : {})['abstract']
    }
  end

  field :journal, types.String, "Journal name" do
    resolve -> (obj, args, ctx) {
      if obj.section
        RecordLoader.for(Section).load(obj.section).then { |section|
          RecordLoader.for(Issue).load(section.issue_id).then { |issue|
            RecordLoader.for(Unit).load(issue.unit_id).then { |unit|
              unit.name
            }
          }
        }
      else
        (obj.attrs ? JSON.parse(obj.attrs) : {}).dig('ext_journal', 'name')
      end
    }
  end

  field :volume, types.String, "Journal volume number" do
    resolve -> (obj, args, ctx) {
      if obj.section
        RecordLoader.for(Section).load(obj.section).then { |section|
          RecordLoader.for(Issue).load(section.issue_id).then { |issue|
            issue.volume
          }
        }
      else
        (obj.attrs ? JSON.parse(obj.attrs) : {}).dig('ext_journal', 'volume')
      end
    }
  end

  field :issue, types.String, "Journal issue number" do
    resolve -> (obj, args, ctx) {
      if obj.section
        RecordLoader.for(Section).load(obj.section).then { |section|
          RecordLoader.for(Issue).load(section.issue_id).then { |issue|
            issue.issue
          }
        }
      else
        (obj.attrs ? JSON.parse(obj.attrs) : {}).dig('ext_journal', 'issue')
      end
    }
  end

  field :issn, types.String, "Journal ISSN" do
    resolve -> (obj, args, ctx) {
      if obj.section
        RecordLoader.for(Section).load(obj.section).then { |section|
          RecordLoader.for(Issue).load(section.issue_id).then { |issue|
            RecordLoader.for(Unit).load(issue.unit_id).then { |unit|
              (unit.attrs ? JSON.parse(unit.attrs) : {})['issn']
            }
          }
        }
      else
        (obj.attrs ? JSON.parse(obj.attrs) : {}).dig('ext_journal', 'issn')
      end
    }
  end

  field :proceedings, types.String, "Proceedings within which item appears (if any)" do
    resolve -> (obj, args, ctx) {
      (obj.attrs ? JSON.parse(obj.attrs) : {})['proceedings']
    }
  end

  field :contributors, ContributorsType, "Editors, advisors, etc. (if any)" do
    argument :first, types.Int, default_value: 100, prepare: ->(val, ctx) {
      (val.nil? || (val >= 1 && val <= 500)) or return GraphQL::ExecutionError.new("'first' must be in range 1..500")
      return val
    }
    argument :more, types.String
    resolve -> (obj, args, ctx) {
      data = ContributorsData.new(args, obj.id)
      data.nodes.then { |nodes|
        nodes && !nodes.empty? ? data : nil
      }
    }
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
      out = (attrs['disciplines'] || []).map{|s| "discipline:#{s}"} +
            (attrs['keywords'] || []).map{|s| "keyword:#{s}"} +
            (attrs['subjects'] || []).map{|s| "subject:#{s}"} +
            (attrs['grants'] || []).map{|s| "grant:#{s['name']}"} +
            ["type:#{obj.genre.sub("dissertation", "etd").upcase.gsub('-','_')}"]
      out.empty? ? nil : out
    }
  end

  field :subjects, types[types.String], "Subject terms (unrestricted) applying to this item" do
    resolve -> (obj, args, ctx) {
      (obj.attrs ? JSON.parse(obj.attrs) : {})['subjects']
    }
  end

  field :keywords, types[types.String], "Keywords (unrestricted) applying to this item" do
    resolve -> (obj, args, ctx) {
      (obj.attrs ? JSON.parse(obj.attrs) : {})['keywords']
    }
  end

  field :disciplines, types[types.String], "Disciplines applying to this item" do
    resolve -> (obj, args, ctx) {
      (obj.attrs ? JSON.parse(obj.attrs) : {})['disciplines']
    }
  end

  field :grants, types[types.String], "Funding grants linked to this item" do
    resolve -> (obj, args, ctx) {
      grants = (obj.attrs ? JSON.parse(obj.attrs) : {})['grants']
      grants ? grants.map { |gr| gr['name'] } : nil
    }
  end

  field :language, types.String, "Language specification (ISO 639-2 code)" do
    resolve -> (obj, args, ctx) {
      (obj.attrs ? JSON.parse(obj.attrs) : {})['language']
    }
  end

  field :embargoExpires, DateType, "Embargo expiration date (if status=EMBARGOED)" do
    resolve -> (obj, args, ctx) {
      (obj.attrs ? JSON.parse(obj.attrs) : {})['embargo_date']
    }
  end

  field :rights, types.String, "License (none, or cc-by-nd, etc.)" do
    resolve -> (obj, args, ctx) {
      obj.status != "published" ? obj.status : obj.rights
    }
  end

  field :fpage, types.String, "First page (within a larger work like a journal issue)" do
    resolve -> (obj, args, ctx) {
      (obj.attrs ? JSON.parse(obj.attrs) : {}).dig('ext_journal', 'fpage')
    }
  end

  field :lpage, types.String, "Last page (within a larger work like a journal issue)" do
    resolve -> (obj, args, ctx) {
      (obj.attrs ? JSON.parse(obj.attrs) : {}).dig('ext_journal', 'lpage')
    }
  end

  field :suppFiles, types[SuppFileType], "Supplemental material (if any)" do
    resolve -> (obj, args, ctx) {
      supps = (obj.attrs ? JSON.parse(obj.attrs) : {})['supp_files']
      if supps
        supps.map { |data| data.merge({item_id: obj.id}) }
      else
        nil
      end
    }
  end

  field :source, !types.String, "Source system within the eScholarship environment" do
    resolve -> (obj, args, ctx) {
      obj.source
    }
  end

  field :ucpmsPubType, types.String, "If publication originated from UCPMS, the type within that system" do
    resolve -> (obj, args, ctx) {
      (obj.attrs ? JSON.parse(obj.attrs) : {})['uc_pms_pub_type']
    }
  end

  field :localIDs, types[LocalIDType], "Local identifiers, e.g. PubMed ID, LBNL, etc." do
    resolve -> (obj, args, ctx) {
      attrs = obj.attrs ? JSON.parse(obj.attrs) : {}
      ids = attrs['local_ids'] || []
      attrs['doi'] and ids.unshift({"type" => "doi", "id" => attrs['doi']})
      ids.empty? ? nil : ids
    }
  end

  field :externalLinks, types[types.String], "Published web location(s) external to eScholarshp" do
    resolve -> (obj, args, ctx) {
      (obj.attrs ? JSON.parse(obj.attrs) : {})['pub_web_loc']
    }
  end

  field :bookTitle, types.String, "Title of the book within which this item appears" do
    resolve -> (obj, args, ctx) {
      (obj.attrs ? JSON.parse(obj.attrs) : {})['book_title']
    }
  end
end

###################################################################################################
LocalIDType = GraphQL::ObjectType.define do
  name "LocalID"
  description "Local item identifier, e.g. PubMed ID, LBNL ID, etc."

  field :id, !types.String, "The identifier string" do
    resolve -> (obj, args, ctx) { obj['id'] }
  end

  field :scheme, !ItemIDSchemeEnum, "The scheme under which the identifier was minted" do
    resolve -> (obj, args, ctx) {
      case obj['type']
        when 'doi';          "DOI"
        when 'lbnl';         "LBNL_PUB_ID"
        when 'oa_harvester'; "OA_PUB_ID"
        else                 "OTHER_ID"
      end
    }
  end

  field :subScheme, types.String, "If scheme is OTHER_ID, this will be more specific" do
    resolve -> (obj, args, ctx) {
      case obj['type']
        when 'doi';          nil
        when 'lbnl';         nil
        when 'oa_harvester'; nil
        else                 obj['type']
      end
    }
  end
end

###################################################################################################
ItemIDSchemeEnum = GraphQL::EnumType.define do
  name "ItemIDScheme"
  description "Ordering for item list results"
  value("ARK", "eSchol (ark:/13030/qt...) or Merritt ARK")
  value("DOI", "A Digital Object Identifier, with or w/o http://dx.doi.org prefix")
  value("LBNL_PUB_ID", "LBNL-internal publication ID")
  value("OA_PUB_ID", "Pub ID on oapolicy.universityofcalifornia.edu")
  value("OTHER_ID", "All other identifiers")
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

    # Apply limits as specified
    args['before'] and query = query.where(Sequel.lit("#{field} < ?", args['before']))
    args['after']  and query = query.where(Sequel.lit("#{field} > ?", args['after']))

    # Matching on tags if specified
    (args['tags'] || []).each { |tag|
      if tag =~ /^discipline:(.*)/
        query = query.where(Sequel.lit(%{json_search(attrs, 'all', ?, null, '$.disciplines') is not null}, $1))
      elsif tag =~ /^keyword:(.*)/
        query = query.where(Sequel.lit(%{lower(attrs->"$.keywords") like ?}, "%#{$1.downcase}%"))
      elsif tag =~ /^subject:(.*)/
        query = query.where(Sequel.lit(%{lower(attrs->"$.subjects") like ?}, "%#{$1.downcase}%"))
      elsif tag =~ /^grant:(.*)/
        query = query.where(Sequel.lit(%{lower(attrs->"$.grants") like ?}, "%#{$1.downcase}%"))
      elsif tag =~ /^type:(.*)/
        query = query.where(genre: $1.downcase == "etd" ? ["etd", "dissertation"] : $1.downcase.gsub("_", "-"))
      else
        raise("tag must start with 'discipline:', 'keyword:', 'subject:', or 'grant:'")
      end
    }

    # Record the base query so if 'total' is requested we count without paging
    @baseQuery = query

    # If this is a 'more' query, add extra constraints so we get the next page (that is,
    # starting just after the end of the last page)
    if args['lastID']
      dir = ascending ? '>' : '<'
      query = query.where(Sequel.lit("#{field} #{dir} ? or (#{field} = ? and id #{dir} ?)",
                                     args['lastDate'], args['lastDate'], args['lastID']))
    end

    @query = query
    @limit = args['first'].to_i
    @args = args.to_h.clone
    @field = field
  end

  def total
    @count ||= @baseQuery.count
  end

  def nodes
    @nodes ||= @query.limit(@limit).all
  end

  # If there might be more in the list, encode all the parameters needed to query for
  # the next page.
  def more
    if nodes().length == @limit
      more = @args.clone
      more['lastID']   = nodes()[-1].id
      more['lastDate'] = nodes()[-1][@field].iso8601
      return Base64.urlsafe_encode64(more.to_json).gsub('=', '')
    else
      return nil
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
    @total ||= CountLoader.for(ItemAuthor, :item_id).load(@itemID)
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

  field :nameParts, NamePartsType, "Individual name parts for special needs" do
    resolve -> (obj, args, ctx) { JSON.parse(obj.attrs) }
  end
end

###################################################################################################
ContributorsType = GraphQL::ObjectType.define do
  name "Contributors"
  description "A list of contributors (e.g. editors, advisors), with rarely-needed paging capability"
  field :total, !types.Int, "Approximate total contributors on all pages"
  field :nodes, !types[ContributorType], "Array of the contribuors on this page"
  field :more, types.String, "Opaque cursor string for next page"
end

###################################################################################################
class ContributorsData
  def initialize(args, itemID)
    # If 'more' was specified, decode it and use all the parameters from the original query
    @args = args['more'] ? JSON.parse(Base64.urlsafe_decode64(args['more'])) : args.to_h.clone

    # Record the item ID for querying
    @itemID = itemID
  end

  def total
    @total ||= CountLoader.for(ItemContrib, :item_id).load(@itemID)
  end

  def nodes
    query = ItemContrib.order(:item_id, :ordering)
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
ContributorType = GraphQL::ObjectType.define do
  name "Contributor"
  description "A single author (can be a person or organization)"

  field :name, !types.String, "Combined name parts; usually 'lname, fname'" do
    resolve -> (obj, args, ctx) { JSON.parse(obj.attrs)['name'] }
  end

  field :role, !RoleEnum, "Role in which this person or org contributed" do
    resolve -> (obj, args, ctx) { obj.role.upcase }
  end

  field :nameParts, NamePartsType, "Individual name parts for special needs" do
    resolve -> (obj, args, ctx) { JSON.parse(obj.attrs) }
  end
end

###################################################################################################
RoleEnum = GraphQL::EnumType.define do
  name "Role"
  description "Publication type of an Item (often ARTICLE)"
  value("ADVISOR", "Advised on the work (e.g. on a thesis)")
  value("EDITOR", "Edited the work")
end

###################################################################################################
NamePartsType = GraphQL::ObjectType.define do
  name "NameParts"
  description "Individual access to parts of the name, generally only used in special cases"
  field :fname, types.String, "First name / given name" do
    resolve -> (obj, args, ctx) { obj['fname'] }
  end
  field :lname, types.String, "Last name / surname" do
    resolve -> (obj, args, ctx) { obj['lname'] }
  end
  field :mname, types.String, "Middle name" do
    resolve -> (obj, args, ctx) { obj['mname'] }
  end
  field :suffix, types.String, "Suffix (e.g. Ph.D)" do
    resolve -> (obj, args, ctx) { obj['suffix'] }
  end
  field :institution, types.String, "Institutional affiliation" do
    resolve -> (obj, args, ctx) { obj['institution'] }
  end
  field :organization, types.String, "Instead of lname/fname if this is a group/corp" do
    resolve -> (obj, args, ctx) { obj['organization'] }
  end
end

###################################################################################################
SuppFileType = GraphQL::ObjectType.define do
  name "SuppFile"
  description "A file containing supplemental material for an item"
  field :file, !types.String, "Name of the file" do
    resolve -> (obj, args, ctx) { obj['file'] }
  end
  field :contentType, types.String, "Content MIME type of file, if known" do
    resolve -> (obj, args, ctx) { obj['mimeType'] }
  end
  field :downloadLink, !types.String, "URL to download the file" do
    resolve -> (obj, args, ctx) { "https://cloudfront.escholarship.org/dist/prd/content/#{obj[:item_id]}/supp/#{obj['file']}" }
  end
end

###################################################################################################
UnitType = GraphQL::ObjectType.define do
  name "Unit"
  description "A campus, department, series, or other organized unit within eScholarship"

  field :id, !types.ID, "Short unit identifier, e.g. 'lbnl_rw'"

  field :name, !types.String, "Human-readable name of the unit"

  field :items, ItemsType, "Query items in the unit (incl. children)" do
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
    argument :tags, types[types.String], description: "Subset items with keyword, subject, discipline, grant, and/or type"
    argument :order, ItemOrderEnum, default_value: "ADDED_DESC",
             description: %{Sets the ordering of results
                            (and affects interpretation of the `before` and `after` arguments)}
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
    argument :tags, types[types.String], description: "Subset items with keyword, subject, discipline, grant, and/or type"
    argument :order, ItemOrderEnum, default_value: "ADDED_DESC",
             description: %{Sets the ordering of results
                            (and affects interpretation of the `before` and `after` arguments)}
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
