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
def loadFilteredUnits(unitIDs, emptyRet = nil)
  unitIDs or return emptyRet
  RecordLoader.for(Unit).load_many(unitIDs).then { |units|
    units.reject! { |u| u.status=="hidden" }
    units.empty? ? emptyRet : units
  }
end

###################################################################################################
ItemType = GraphQL::ObjectType.define do
  name "Item"
  description "An item"

  field :id, !types.ID, "eScholarship ARK identifier" do
    resolve -> (obj, args, ctx) { "ark:/13030/#{obj.id}" }
  end

  field :title, !types.String, "Title of the item (may include embedded HTML formatting tags)" do
    resolve -> (obj, args, ctx) { obj.title || "" }  # very few null titles; just call it empty string
  end

  field :status, !ItemStatusEnum, "Publication status; usually PUBLISHED" do
    resolve -> (obj, args, ctx) { obj.status.sub("withdrawn-junk", "withdrawn").upcase }
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

  field :permalink, !types.String, "Permanent link to the item on eScholarship" do
    resolve -> (obj, args, ctx) { "#{ENV['ESCHOL_FRONTEND_URL']}/uc/item/#{obj.id.sub(/^qt/,'')}" }
  end

  field :contentType, types.String, "Main content MIME type (e.g. application/pdf)" do
    resolve -> (obj, args, ctx) { obj.content_type }
  end

  field :contentLink, types.String, "Download link for PDF/content file (if applicable)" do
    resolve -> (obj, args, ctx) {
      content_prefix = ENV['CLOUDFRONT_PUBLIC_URL'] || Thread.current[:baseURL]
      obj.status == "published" && obj.content_type == "application/pdf" ?
        "#{content_prefix}/content/#{obj.id}/#{obj.id}.pdf" : nil
    }
  end

  field :contentSize, types.Int, "Size of PDF/content file in bytes (if applicable)" do
    resolve -> (obj, args, ctx) {
      (obj.attrs ? JSON.parse(obj.attrs) : {})['content_length']
    }
  end

  # TODO: Test this
  field :contentVersion, FileVersionEnum, "Version of a content file, e.g. AUTHOR_VERSION" do
    resolve -> (obj, args, ctx) {
      !!((obj.attrs ? JSON.parse(obj.attrs) : {})['content_version'])
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

  field :publisher, types.String, "Publisher of the item (if any)" do
    resolve -> (obj, args, ctx) {
      (obj.attrs ? JSON.parse(obj.attrs) : {})['publisher']
    }
  end

  field :proceedings, types.String, "Proceedings within which item appears (if any)" do
    resolve -> (obj, args, ctx) {
      (obj.attrs ? JSON.parse(obj.attrs) : {})['proceedings']
    }
  end

  field :isbn, types.String, "Book ISBN" do
    resolve -> (obj, args, ctx) {
      (obj.attrs ? JSON.parse(obj.attrs) : {})['isbn']
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

  field :units, types[UnitType], "The series/unit id(s) associated with this item" do
    resolve -> (obj, args, ctx) {
      query = UnitItem.where(is_direct: true).order(:item_id, :ordering_of_units).select(:item_id, :unit_id)
      GroupLoader.for(query, :item_id).load(obj.id).then { |unitItems|
        unitItems ? loadFilteredUnits(unitItems.map { |unitItem| unitItem.unit_id }, []) : nil
      }
    }
  end

  field :tags, types[types.String], "Unified disciplines, keywords, grants, etc." do
    resolve -> (obj, args, ctx) {
      attrs = obj.attrs ? JSON.parse(obj.attrs) : {}
      out = (attrs['disciplines'] || []).map{|s| "discipline:#{s}"} +
            (attrs['keywords'] || []).map{|s| "keyword:#{s}"} +
            (attrs['subjects'] || []).map{|s| "subject:#{s}"} +
            (attrs['grants'] || []).map{|s| "grant:#{s['name']}"} +
            ["source:#{obj.source}"] +
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
      obj.rights
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

  field :pagination, types.String, "Combined first page - last page" do
    resolve -> (obj, args, ctx) {
      attrs = obj.attrs ? JSON.parse(obj.attrs) : {}
      fpage = attrs.dig('ext_journal', 'fpage')
      lpage = attrs.dig('ext_journal', 'lpage')
      fpage ? (lpage ? "#{fpage}-#{lpage}" : fpage) : lpage
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

  field :localIDs, types[LocalIDType], "Local item identifiers, e.g. DOI, PubMed ID, LBNL, etc." do
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

  field :nativeFileName, types.String, "Name of original (pre-PDF-conversion) file" do
    resolve -> (obj, args, ctx) {
      (obj.attrs ? JSON.parse(obj.attrs) : {}).dig('native_file', 'name')
    }
  end

  field :nativeFileSize, types.String, "Size of original (pre-PDF-conversion) file" do
    resolve -> (obj, args, ctx) {
      (obj.attrs ? JSON.parse(obj.attrs) : {}).dig('native_file', 'size')
    }
  end

  field :isPeerReviewed, types.Boolean, "Whether the work has undergone a peer review process" do
    resolve -> (obj, args, ctx) {
      !!((obj.attrs ? JSON.parse(obj.attrs) : {})['is_peer_reviewed'])
    }
  end
end

###################################################################################################
LocalIDType = GraphQL::ObjectType.define do
  name "LocalID"
  description "Local item identifier, e.g. DOI, PubMed ID, LBNL ID, etc."

  field :id, !types.String, "The identifier string" do
    resolve -> (obj, args, ctx) { obj['id'] }
  end

  field :scheme, !ItemIDSchemeEnum, "The scheme under which the identifier was minted" do
    resolve -> (obj, args, ctx) {
      case obj['type']
        when 'merritt';      "ARK"
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
        when 'merritt';      "Merritt"
        when 'doi';          nil
        when 'lbnl';         nil
        when 'oa_harvester'; nil
        else                 obj['type']
      end
    }
  end
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
  def initialize(args, ctx, unitID: nil, itemID: nil, personID: nil,
                 authorID: nil, authorScheme: nil, authorSubScheme: nil)
    # Query by status, defaulting to PUBLISHED only
    statuses = (args['include'] || ['PUBLISHED']).map { |statusEnum| statusEnum.downcase }
    query = Item.where(status: statuses)

    # If 'more' was specified, decode it and use all the parameters from the original query
    if args['more']
      args = JSON.parse(Base64.urlsafe_decode64(args['more']))
      args['before'] and args['before'] = DateTime.parse(args['before'])
      args['after'] and args['after'] = DateTime.parse(args['after'])
    end

    # If this is a unit query, restrict to items within that unit.
    if unitID
      query = query.where(Sequel.lit("id in (select item_id from unit_items where unit_id = ?)", unitID))
    end

    # If this is an author query, restrict to items by that author. In the case of an author with
    # no ID, this amounts to a single item.
    if personID
      query = query.where(Sequel.lit("id in (select item_id from item_authors where person_id = ?)", personID))
    end
    puts "authorID=#{authorID.inspect} authorScheme=#{authorScheme.inspect} sub=#{authorSubScheme.inspect}"
    if authorID
      case authorScheme
        when 'ARK'
          query = query.where(Sequel.lit("id in (select item_id from item_authors where person_id = ?)", authorID))
        when 'ORCID'
          query = query.where(Sequel.lit("id in (select item_id from item_authors where attrs->>'$.ORCID_id' = ?)", authorID))
        when 'OTHER_ID'
          authorSubScheme =~ /^[\w_]+$/ or raise
          query = query.where(Sequel.lit("id in (select item_id from item_authors " +
                                         "where attrs->>'$.#{authorSubScheme}_id' = ?)", authorID))
        else raise
      end
    end
    if itemID
      query = query.where(id: itemID)
    end

    # Let's get the ordering correct -- using the right field, and either ascending or descending
    field = args['order'].sub(/_.*/,'').downcase.to_sym
    ascending = (args['order'] =~ /ASC/)
    query = query.order(ascending ? field : Sequel::desc(field),
                        ascending ? :id   : Sequel::desc(:id))

    # Apply limits as specified
    if args['before']
      # Exclusive ('<'), so that queries like "after: 2018-11-01 before: 2018-12-01" work as user expects.
      query = query.where(Sequel.lit("#{field} < ?", field == :updated ? args['before'] : args['before'].to_date))
    end
    if args['after']
      # Inclusive ('>='), so that queries like "after: 2018-11-01 before: 2018-12-01" work as user expects.
      query = query.where(Sequel.lit("#{field} >= ?", field == :updated ? args['after'] : args['after'].to_date))
    end

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
      elsif tag =~ /^source:(.*)/
        query = query.where(source: $1)
      else
        raise("tags must start with 'discipline:', 'keyword:', 'subject:', 'grant:', 'type:', or 'source:'")
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
  field :total, !types.Int, "Approximate total authors on all pages"
  field :nodes, !types[AuthorType], "Array of the authors on this page" do
    resolve -> (obj, args, ctx) {
      obj.nodes.then { |nodes|
        nodes.each { |node| node['itemID'] = obj.itemID }
        nodes
      }
    }
  end
  field :more, types.String, "Opaque cursor string for next page"
end

###################################################################################################
class AuthorsData
  attr_accessor :itemID

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
AuthorIDType = GraphQL::ObjectType.define do
  name "AuthorID"
  description "Author identifier, e.g. escholarship, ORCID, other."

  field :id, !types.String, "The identifier string" do
    resolve -> (obj, args, ctx) { obj['id'] }
  end

  field :scheme, !AuthorIDSchemeEnum, "The scheme under which the identifier was minted" do
    resolve -> (obj, args, ctx) {
      case obj['type']
        when 'ARK';   "ARK"
        when 'ORCID'; "ORCID"
        else          "OTHER_ID"
      end
    }
  end

  field :subScheme, types.String, "If scheme is OTHER_ID, this will be more specific" do
    resolve -> (obj, args, ctx) {
      case obj['type']
        when 'ARK'; nil
        when 'ORCID'; nil
        else obj['type']
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

  field :id, types.ID, "eSchol person ID (many authors have none)" do
    resolve -> (obj, args, ctx) { obj.person_id }
  end

  field :variants, !types[NamePartsType], "All name variants" do
    resolve -> (obj, args, ctx) {
      if obj.person_id
        variants = Set.new
        ItemAuthor.where(person_id: obj.person_id).each { |other|
          otherAttrs = JSON.parse(other.attrs)
          otherAttrs.delete('email')
          variants << otherAttrs
        }
        variants.to_a.sort { |a,b| a.to_s <=> b.to_s }
      else
        [JSON.parse(obj.attrs)]
      end
    }
  end

  field :items, ItemsType, "Query items by this author" do
    defineItemsArgs
    resolve -> (obj, args, ctx) {
      attrs = obj.attrs ? JSON.parse(obj.attrs) : {}
      idKey = obj[:idSchemeHint] || attrs.keys.find{ |key| key =~ /_id$/ }
      puts("Scheme hint: #{obj[:idSchemeHint]}")
      if obj.person_id && !obj[:idSchemeHint]
        ItemsData.new(args, ctx, personID: obj.person_id)
      elsif idKey
        ItemsData.new(args, ctx,
                      authorID: attrs[idKey],
                      authorScheme: idKey == "ORCID_id" ? "ORCID" : "OTHER_ID",
                      authorSubScheme: idKey == "ORCID_id" ? nil : idKey.sub(/_id$/, ''))
      else
        itemID = obj.values['itemID']
        itemID or raise("internal error: must have itemID or person_id")
        ItemsData.new(args, ctx, itemID: itemID)
      end
    }
  end

  field :email, types.String, "Email (restricted field)" do
    resolve -> (obj, args, ctx) {
      Thread.current[:privileged] or return GraphQL::ExecutionError.new("'email' field is restricted")
      JSON.parse(obj.attrs)['email']
    }
  end

  field :orcid, types.String, "ORCID identifier" do
    resolve -> (obj, args, ctx) {
      JSON.parse(obj.attrs)['ORCID_id']
    }
  end

  field :ids, types[AuthorIDType], "Unified author identifiers, e.g. eschol ARK, ORCID, OTHER." do
    resolve -> (obj, args, ctx) {
      attrs = JSON.parse(obj.attrs)
      ids = [obj.person_id ? {'type' => 'ARK', 'id' => obj.person_id} : nil] + attrs.sort.each.map { |type, id|
        type =~ /_id$/ ? { 'type' => type.sub('_id', ''), 'id' => id } : nil
      }
      ids.compact!
      return ids.empty? ? nil : ids
    }
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

  field :email, types.String, "Email (restricted field)" do
    resolve -> (obj, args, ctx) {
      Thread.current[:privileged] or return GraphQL::ExecutionError.new("'email' field is restricted")
      JSON.parse(obj.attrs)['email']
    }
  end
end

###################################################################################################
NamePartsType = GraphQL::ObjectType.define do
  name "NameParts"
  description "Individual access to parts of the name, generally only used in special cases"
  field :name, !types.String, "Combined name parts; usually 'lname, fname'" do
    resolve -> (obj, args, ctx) { obj['name'] }
  end

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
  field :size, types.Int, "Size of the file in bytes" do
    resolve -> (obj, args, ctx) { obj['size'] }
  end
  field :downloadLink, !types.String, "URL to download the file" do
    resolve -> (obj, args, ctx) {
      content_prefix = ENV['CLOUDFRONT_PUBLIC_URL'] || Thread.current[:baseURL]
      "#{content_prefix}/content/#{obj[:item_id]}/supp/#{obj['file']}"
    }
  end
end

###################################################################################################
UnitsType = GraphQL::ObjectType.define do
  name "Units"
  description "A list of units, with paging capability because there are thousands"

  field :total, !types.Int, "Approximate total units on all pages" do
    resolve -> (obj, args, ctx) { obj.total }
  end

  field :nodes, !types[UnitType], "Array of the units on this page" do
    resolve -> (obj, args, ctx) { obj.nodes }
  end

  field :more, types.String, "Opaque cursor string for next page" do
    resolve -> (obj, args, ctx) { obj.more }
  end
end

###################################################################################################
class UnitsData
  def initialize(args, ctx, ancestorUnit)
    query = Unit.join(:unit_hier, unit_id: :id).
                 exclude(status: 'hidden').
                 where(ancestor_unit: ancestorUnit).
                 order(:unit_id)

    # If 'more' was specified, decode it and use all the parameters from the original query
    args['more'] and args = JSON.parse(Base64.urlsafe_decode64(args['more']))

    # If this is a type query, restrict to units of that type
    if args['type']
      query = query.where(type: args['type'].downcase)
    end

    # Record the base query so if 'total' is requested we count without paging
    @baseQuery = query

    # If this is a 'more' query, add extra constraints so we get the next page (that is,
    # starting just after the end of the last page)
    if args['lastID']
      query = query.where(Sequel.lit("unit_id > ?", args['lastID']))
    end

    @query = query
    @limit = args['first'].to_i
    @args = args.to_h.clone
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
      return Base64.urlsafe_encode64(more.to_json).gsub('=', '')
    else
      return nil
    end
  end
end

###################################################################################################
IssueType = GraphQL::ObjectType.define do
  name "Issue"
  description "A single issue of a journal"

  field :volume, types.String, "Volume number (sometimes null for issue-only journals)"
  field :issue, types.String, "Issue number (sometimes null for volume-only journals)"
  field :published, !types.String, "Date the item was published"
end

###################################################################################################
UnitType = GraphQL::ObjectType.define do
  name "Unit"
  description "A campus, department, series, or other organized unit within eScholarship"

  field :id, !types.ID, "Short unit identifier, e.g. 'lbnl_rw'"

  field :name, !types.String, "Human-readable name of the unit"

  field :type, !UnitTypeEnum, "Type of unit, e.g. ORU, SERIES, JOURNAL" do
    resolve -> (obj, args, ctx) {
      obj.type.upcase
    }
  end

  field :issn, types.String, "ISSN, applies to units of type=JOURNAL only" do
    resolve -> (obj, args, ctx) {
      (obj.attrs ? JSON.parse(obj.attrs) : {})['issn']
    }
  end

  field :items, ItemsType, "Query items in the unit (incl. children)" do
    defineItemsArgs
    resolve -> (obj, args, ctx) { ItemsData.new(args, ctx, unitID: obj.id) }
  end

  field :children, types[UnitType], "Direct hierarchical children (i.e. sub-units)" do
    resolve -> (obj, args, ctx) {
      query = UnitHier.where(is_direct: true).
                       exclude(status: 'hidden').
                       order(:ordering).
                       select(:ancestor_unit, :unit_id)
      GroupLoader.for(query, :ancestor_unit).load(obj.id).then { |unitHiers|
        unitHiers ? loadFilteredUnits(unitHiers.map { |pu| pu.unit_id }) : nil
      }
    }
  end

  field :descendants, UnitsType, "Query all children, grandchildren, etc. of this unit" do
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
    argument :type, UnitTypeEnum, description: "Type of unit, e.g. ORU, SERIES, JOURNAL"
    resolve -> (obj, args, ctx) {
      UnitsData.new(args, ctx, obj.id)
    }
  end

  field :parents, types[UnitType], "Direct hierarchical parent(s) (i.e. owning units)" do
    resolve -> (obj, args, ctx) {
      query = UnitHier.where(is_direct: true).order(:ordering).select(:ancestor_unit, :unit_id)
      GroupLoader.for(query, :unit_id).load(obj.id).then { |unitHiers|
        unitHiers ? loadFilteredUnits(unitHiers.map { |pu| pu.ancestor_unit }) : nil
      }
    }
  end

  field :issues, types[IssueType], "All journal issues published by this unit (only applies if type=JOURNAL)" do
    resolve -> (obj, args, ctx) {
      query = Issue.order(:published, :volume, :issue)
      GroupLoader.for(query, :unit_id).load(obj.id)
    }
  end
end

###################################################################################################
UnitTypeEnum = GraphQL::EnumType.define do
  name "UnitType"
  description "Type of unit within eScholarship"
  value("CAMPUS",           "campus within the UC system")
  value("JOURNAL",          "journal hosted by eScholarship")
  value("MONOGRAPH_SERIES", "series of monographs")
  value("ORU",              "general Organized Research Unit; often a dept.")
  value("ROOT",             "eScholarship itself")
  value("SEMINAR_SERIES",   "series of seminars")
  value("SERIES",           "general series of publications")
end

###################################################################################################
def defineItemsArgs
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
  argument :include, types[ItemStatusEnum], description: "Include items w/ given status(es). Defaults to PUBLISHED only."
  argument :tags, types[types.String], description: %{
             Subset items with keyword, subject, discipline, grant, type, and/or source.
             E.g. 'tags: ["keyword=food"]' or 'tags: ["grant:USDOE"]'}.unindent
  argument :order, ItemOrderEnum, default_value: "ADDED_DESC",
           description: %{Sets the ordering of results
                          (and affects interpretation of the `before` and `after` arguments)}
end

###################################################################################################
AccessQueryType = GraphQL::ObjectType.define do
  name "AccessQuery"
  description "The eScholarship access API"

  field :item, ItemType, "Get item's info given its identifier" do
    argument :id, !types.ID
    argument :scheme, ItemIDSchemeEnum
    resolve -> (obj, args, ctx) {
      scheme = args["scheme"] || "ARK"
      id = args["id"]
      if scheme == "ARK" && id =~ %r{^ark:/13030/(qt\w{8})$}
        return Item[$1]
      elsif scheme == "DOI" && id =~ /^.*?\b(10\..*)$/
        return Item.where(Sequel.lit(%{attrs->>"$.doi" like ?}, "%#{$1}")).first
      elsif %w{LBNL_PUB_ID OA_PUB_ID ARK}.include?(scheme)
        Item.where(Sequel.lit(%{attrs->"$.local_ids" like ?}, "%#{id}%")).limit(100).each { |item|
          attrs = item.attrs ? JSON.parse(item.attrs) : {}
          (attrs['local_ids'] || []).each { |loc|
            next unless loc['id'] == id
            if scheme == "LBNL_PUB_ID" && loc['type'] == 'lbnl'
              return item
            elsif scheme == "OA_PUB_ID" && loc['type'] == 'oa_harvester'
              return item
            elsif scheme == "ARK" && loc['type'] == 'merritt'
              return item
            end
          }
        }
        return nil
      else
        return GraphQL::ExecutionError.new("currently unsupported scheme for querying")
      end
    }
  end

  field :items, ItemsType, "Query a list of all items" do
    defineItemsArgs
    resolve -> (obj, args, ctx) { ItemsData.new(args, ctx) }
  end

  field :unit, UnitType, "Get a unit given its identifier" do
    argument :id, !types.ID
    resolve -> (obj, args, ctx) { Unit[args["id"]] }
  end

  field :rootUnit, !UnitType, "The root of the unit hierarchy (eSchol itself)" do
    resolve -> (obj, args, ctx) { Unit["root"] }
  end

  field :author, AuthorType, "Get an author by ID (scheme optional, defaults to eschol ARK), or email address" do
    argument :id, types.ID
    argument :scheme, AuthorIDSchemeEnum
    argument :subScheme, types.String
    argument :email, types.String
    resolve -> (obj, args, ctx) {
      id, email, scheme, subScheme = args['id'], args['email'], args['scheme'], args['subScheme']
      if (id && email) || (!id && !email)
        return GraphQL::ExecutionError.new("must specify either 'id' or 'email'")
      elsif args['id']
        case scheme
          when nil, 'ARK'; person = Person[args['id']]
          when 'ORCID';
            record = Person.where(Sequel.lit(%{attrs->>"$.ORCID_id" = ?}, id)).first
            record or record = ItemAuthor.where(Sequel.lit(%{attrs->>"$.ORCID_id" = ?}, id)).first
            record and record[:idSchemeHint] = 'ORCID_id'
            return record
          when 'OTHER_ID';
            subScheme =~ /^[\w_]+$/ or return GraphQL::ExecutionError.new("valid subScheme required with 'OTHER' scheme")
            record = ItemAuthor.where(Sequel.lit(%{attrs->>"$.#{subScheme}_id" = ?}, id)).first
            record and record[:idSchemeHint] = "#{subScheme}_id"
            return record
          else raise
        end
      elsif args['email']
        person = Person.where(Sequel.lit(%{lower(attrs->>"$.email") = ?}, email.downcase)).first
        person or return ItemAuthor.where(Sequel.lit(%{lower(attrs->>"$.email") = ?}, email.downcase)).first
      else
        raise
      end
      person or return nil
      return ItemAuthor.where(person_id: person.id).first
    }
  end
end
