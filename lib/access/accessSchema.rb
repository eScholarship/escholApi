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

def is_withdrawn(obj)
  obj.status == "withdrawn" or obj.status == "withdrawn-junk"
end


###################################################################################################
# Forward declare ItemsType
class ItemsType < GraphQL::Schema::Object
end
class UnitsType < GraphQL::Schema::Object
end
###################################################################################################
class ItemOrderEnum < GraphQL::Schema::Enum
  graphql_name "ItemOrder"
  description "Ordering for item list results"
  value("ADDED_ASC", "Date added to eScholarship, oldest to newest")
  value("ADDED_DESC", "Date added to eScholarship, newest to oldest")
  value("PUBLISHED_ASC", "Date published, oldest to newest")
  value("PUBLISHED_DESC", "Date published, newest to oldest")
  value("UPDATED_ASC", "Date updated in eScholarship, oldest to newest")
  value("UPDATED_DESC", "Date updated in eScholarship, newest to oldest")
end

###################################################################################################
class ItemStatusEnum < GraphQL::Schema::Enum
  graphql_name "ItemStatus"
  description "Publication status of an Item (usually PUBLISHED)"
  value("EMBARGOED", "Currently under embargo (omitted from queries)")
  value("EMPTY", "Item was published but has no link or files (omitted from queries)")
  value("PUBLISHED", "Normal published item")
  value("WITHDRAWN", "Item was withdrawn (omitted from queries)")
  value("PENDING", "Item is still pending")
end

###################################################################################################
class ItemTypeEnum < GraphQL::Schema::Enum
  graphql_name "ItemType"
  description "Publication type of an Item (often ARTICLE)"
  value("ARTICLE", "Normal article, e.g. a journal article")
  value("CHAPTER", "Chapter within a book/monograph")
  value("ETD", "Electronic thesis/dissertation")
  value("MONOGRAPH", "A book / monograph")
  value("MULTIMEDIA", "Multimedia (e.g. video, audio, etc.)")
  value("NON_TEXTUAL", "Other non-textual work")
end

###################################################################################################
class AuthorIDType < GraphQL::Schema::Object
  graphql_name "AuthorID"
  description "Author identifier, e.g. escholarship, ORCID, other."

  field :id, String, "The identifier string" do
    def resolve(obj, args, ctx) 
      obj = obj.object
      obj['id'] 
    end
  end

  field :scheme, AuthorIDSchemeEnum, "The scheme under which the identifier was minted", null: false do
    def resolve(obj, args, ctx)
      obj = obj.object
      case obj['type']
        when 'ARK';   "ARK"
        when 'ORCID'; "ORCID"
        else          "OTHER_ID"
      end
    end
  end

  field :subScheme, String, "If scheme is OTHER_ID, this will be more specific" do
    def resolve(obj, args, ctx)
     obj = obj.object
      case obj['type']
        when 'ARK'; nil
        when 'ORCID'; nil
        else obj['type']
      end
    end
  end
end

###################################################################################################
class NamePartsType < GraphQL::Schema::Object
  graphql_name "NameParts"
  description "Individual access to parts of the name, generally only used in special cases"
  field :name, String, "Combined name parts; usually 'lname, fname'", null: false do
    def resolve(obj, args, ctx) 
      obj = obj.object
      obj['name']
    end
  end

  field :fname, String, "First name / given name" do
    def resolve(obj, args, ctx)
      obj = obj.object
      obj['fname'] 
    end
  end
  field :lname, String, "Last name / surname" do
    def resolve(obj, args, ctx) 
      obj = obj.object
      obj['lname'] 
    end
  end
  field :mname, String, "Middle name" do
    def resolve(obj, args, ctx) 
      obj = obj.object
      obj['mname'] 
    end
  end
  field :suffix, String, "Suffix (e.g. Ph.D)" do
    def resolve(obj, args, ctx) 
      obj = obj.object
      obj['suffix'] 
    end
  end
  field :institution, String, "Institutional affiliation" do
    def resolve(obj, args, ctx) 
      obj = obj.object
      obj['institution'] 
    end
  end
  field :organization, String, "Instead of lname/fname if this is a group/corp" do
    def resolve(obj, args, ctx) 
      obj = obj.object
      obj['organization'] 
    end
  end
end
###################################################################################################
class AuthorType < GraphQL::Schema::Object
  graphql_name "Author"
  description "A single author (can be a person or organization)"

  field :name, String, "Combined name parts; usually 'lname, fname'", null: false do
    def resolve(obj, args, ctx) 
      obj = obj.object
      JSON.parse(obj.attrs)['name'] 
    end
  end

  field :nameParts, NamePartsType, "Individual name parts for special needs" do
    def resolve(obj, args, ctx) 
      obj = obj.object
      JSON.parse(obj.attrs) 
    end
  end

  field :id, ID, "eSchol person ID (many authors have none)" do
    def resolve(obj, args, ctx) 
      obj = obj.object
      obj.person_id 
    end
  end

  field :variants, [NamePartsType], "All name variants", null: false do
    def resolve(obj, args, ctx) 
      obj = obj.object
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
    end
  end
  
  field :items, ItemsType, "Query items by this author" do
    defineItemsArgs
    def resolve(obj, args, ctx)
      obj = obj.object 
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
    end
  end

  field :email, String, "Email (restricted field)" do
    def resolve(obj, args, ctx) 
      obj = obj.object
      Thread.current[:privileged] or return GraphQL::ExecutionError.new("'email' field is restricted")
      JSON.parse(obj.attrs)['email']
    end
  end

  field :orcid, String, "ORCID identifier" do
    def resolve(obj, args, ctx) 
      obj = obj.object
      JSON.parse(obj.attrs)['ORCID_id']
    end
  end

  field :ids, [AuthorIDType], "Unified author identifiers, e.g. eschol ARK, ORCID, OTHER." do
    def resolve(obj, args, ctx) 
      obj = obj.object
      attrs = JSON.parse(obj.attrs)
      ids = [obj.person_id ? {'type' => 'ARK', 'id' => obj.person_id} : nil] + attrs.sort.each.map { |type, id|
        type =~ /_id$/ ? { 'type' => type.sub('_id', ''), 'id' => id } : nil
      }
      ids.compact!
      return ids.empty? ? nil : ids
    end
  end
end
###################################################################################################
class AuthorsType < GraphQL::Schema::Object
  graphql_name "Authors"
  description "A list of authors, with paging capability because some items have thousands"
  field :total, Int, "Approximate total authors on all pages", null: false
  field :nodes, [AuthorType], "Array of the authors on this page", null: false do
    def resolve(obj, args, ctx) 
      obj = obj.object
      obj.nodes.then { |nodes|
        nodes.each { |node| node['itemID'] = obj.itemID }
        nodes
      }
    end
  end
  field :more, String, "Opaque cursor string for next page"
end


###################################################################################################
class ContributorType < GraphQL::Schema::Object
  graphql_name "Contributor"
  description "A single author (can be a person or organization)"

  field :name, String, "Combined name parts; usually 'lname, fname'", null: false do
    def resolve(obj, args, ctx) 
      obj = obj.object
      JSON.parse(obj.attrs)['name'] 
    end
  end

  field :role, RoleEnum, "Role in which this person or org contributed", null:false do
    def resolve(obj, args, ctx) 
      obj = obj.object
      obj.role.upcase 
    end
  end

  field :nameParts, NamePartsType, "Individual name parts for special needs" do
    def resolve(obj, args, ctx) 
      obj = obj.object
      JSON.parse(obj.attrs) 
    end
  end

  field :email, String, "Email (restricted field)" do
    def resolve(obj, args, ctx) 
      obj = obj.object
      Thread.current[:privileged] or return GraphQL::ExecutionError.new("'email' field is restricted")
      JSON.parse(obj.attrs)['email']
    end
  end
end

###################################################################################################
class ContributorsType < GraphQL::Schema::Object
  graphql_name "Contributors"
  description "A list of contributors (e.g. editors, advisors), with rarely-needed paging capability"
  field :total, Int, "Approximate total contributors on all pages", null: false
  field :nodes, [ContributorType], "Array of the contribuors on this page", null: false
  field :more, String, "Opaque cursor string for next page"
end


###################################################################################################
class IssueType < GraphQL::Schema::Object
  graphql_name "Issue"
  description "A single issue of a journal"

  field :volume, String, "Volume number (sometimes null for issue-only journals)"
  field :issue, String, "Issue number (sometimes null for volume-only journals)"
  field :published, String, "Date the item was published", null: false
end

###################################################################################################
class UnitTypeEnum < GraphQL::Schema::Enum
  graphql_name "UnitType"
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
class UnitType < GraphQL::Schema::Object
  graphql_name "Unit"
  description "A campus, department, series, or other organized unit within eScholarship"

  field :id, ID, "Short unit identifier, e.g. 'lbnl_rw'", null: false

  field :name, String, "Human-readable name of the unit", null: false

  field :type, UnitTypeEnum, "Type of unit, e.g. ORU, SERIES, JOURNAL", null: false do
    def resolve(obj, args, ctx) 
      obj = obj.object
      obj.type.upcase
    end
  end

  field :issn, String, "ISSN, applies to units of type=JOURNAL only" do
    def resolve(obj, args, ctx)
      obj = obj.object
      (obj.attrs ? JSON.parse(obj.attrs) : {})['issn']
    end
  end


  field :items, ItemsType, "Query items in the unit (incl. children)" do
    defineItemsArgs
    def resolve(obj, args, ctx) 
      obj = obj.object
      ItemsData.new(args, ctx, unitID: obj.id) 
    end
  end

  field :ucpmsId, Int, "Elements ID for the unit" do
    def resolve(obj, args, ctx) 
      obj = obj.object
      (obj.attrs ? JSON.parse(obj.attrs) : {})['elements_id']
    end
  end

  field :children, [UnitType], "Direct hierarchical children (i.e. sub-units)" do
    def resolve(obj, args, ctx) 
      obj = obj.object
      query = UnitHier.where(is_direct: true).
                       order(:ordering).
                       select(:ancestor_unit, :unit_id)

      GroupLoader.for(query, :ancestor_unit).load(obj.id).then { |unitHiers|
        unitHiers ? loadFilteredUnits(unitHiers.map { |pu| pu.unit_id }) : nil
      }
    end
  end

  field :descendants, UnitsType, "Query all children, grandchildren, etc. of this unit" do
    argument :first, Int, default_value: 100,
      description: "Number of results to return (values 1..500 are valid)",
      prepare: ->(val, ctx) {
        (val.nil? || (val >= 1 && val <= 500)) or return GraphQL::ExecutionError.new("'first' must be in range 1..500")
        return val
      }
    argument :more, String, required: false, description: %{Opaque string obtained from the `more` field of a prior result,
                                                 and used to fetch the next set of nodes.
                                                 Do not specify any other arguments with this one; the string already
                                                 encodes the prior set of arguments.}.unindent
    argument :type, UnitTypeEnum, required: false, description: "Type of unit, e.g. ORU, SERIES, JOURNAL"
    def resolve(obj, args, ctx) 
      obj = obj.object
      UnitsData.new(args, ctx, obj.id)
    end
  end

  field :parents, [UnitType], "Direct hierarchical parent(s) (i.e. owning units)" do
    def resolve(obj, args, ctx) 
      obj = obj.object
      query = UnitHier.where(is_direct: true).order(:ordering).select(:ancestor_unit, :unit_id)
      GroupLoader.for(query, :unit_id).load(obj.id).then { |unitHiers|
        unitHiers ? loadFilteredUnits(unitHiers.map { |pu| pu.ancestor_unit }) : nil
      }
    end
  end

  field :issues, [IssueType], "All journal issues published by this unit (only applies if type=JOURNAL)" do
    def resolve(obj, args, ctx) 
      obj = obj.object
      query = Issue.order(:published, :volume, :issue)
      GroupLoader.for(query, :unit_id).load(obj.id)
    end
  end
end

###################################################################################################
class UnitsType < GraphQL::Schema::Object
  graphql_name "Units"
  description "A list of units, with paging capability because there are thousands"

  field :total, Int, "Approximate total units on all pages", null: false do
    def resolve(obj, args, ctx) 
      obj = obj.object
      obj.total 
    end
  end

  field :nodes, [UnitType], "Array of the units on this page", null: false do
    def resolve(obj, args, ctx) 
      obj = obj.object
      obj.nodes 
    end
  end

  field :more, String, "Opaque cursor string for next page" do
    def resolve(obj, args, ctx) 
      obj = obj.object
      obj.more 
    end
  end
end

###################################################################################################
class SuppFileType < GraphQL::Schema::Object
  graphql_name "SuppFile"
  description "A file containing supplemental material for an item"
  field :file, String, "Name of the file", null: false do
    def resolve(obj, args, ctx) 
      obj = obj.object
      obj['file'] 
    end
  end
  field :contentType, String, "Content MIME type of file, if known" do
    def resolve(obj, args, ctx) 
      obj = obj.object
      obj['mimeType'] 
    end
  end
  field :size, GraphQL::Types::BigInt, "Size of the file in bytes" do
    def resolve(obj, args, ctx) 
      obj = obj.object
      obj['size'] 
    end
  end
  field :downloadLink, String, "URL to download the file", null: false do
    def resolve(obj, args, ctx) 
      obj = obj.object
      content_prefix = ENV['CLOUDFRONT_PUBLIC_URL'] || Thread.current[:baseURL]
      "#{content_prefix}/content/#{obj[:item_id]}/supp/#{obj['file']}"
    end
  end
end


###################################################################################################
class LocalIDType < GraphQL::Schema::Object
  graphql_name "LocalID"
  description "Local item identifier, e.g. DOI, PubMed ID, LBNL ID, etc."

  field :id, String, "The identifier string", null: false do
    def resolve(obj, args, ctx) 
      obj = obj.object
      obj['id'] 
    end
  end

  field :scheme, ItemIDSchemeEnum, "The scheme under which the identifier was minted", null: false do
    def resolve(obj, args, ctx) 
      obj = obj.object
      case obj['type']
        when 'merritt';      "ARK"
        when 'doi';          "DOI"
        when 'lbnl';         "LBNL_PUB_ID"
        when 'oa_harvester'; "OA_PUB_ID"
        else                 "OTHER_ID"
      end
    end
  end

  field :subScheme, String, "If scheme is OTHER_ID, this will be more specific" do
    def resolve(obj, args, ctx) 
      obj = obj.object
      case obj['type']
        when 'merritt';      "Merritt"
        when 'doi';          nil
        when 'lbnl';         nil
        when 'oa_harvester'; nil
        else                 obj['type']
      end
    end
  end
end


###################################################################################################
class ItemType < GraphQL::Schema::Object
  graphql_name "Item"
  description "An item"

  field :id, ID, "eScholarship ARK identifier", null: false do
    def resolve(obj, args, ctx)  
      obj = obj.object
      "ark:/13030/#{obj.id}" 
    end 
  end

  field :title, String, "Title of the item (may include embedded HTML formatting tags)", null: false do
    def resolve(obj, args, ctx) 
      obj = obj.object
      obj.title || "" 
      # very few null titles; just call it empty string
    end
  end

  field :status, ItemStatusEnum, "Publication status; usually PUBLISHED", null: false do
    def resolve(obj, args, ctx) 
      obj = obj.object
      obj.status.sub("withdrawn-junk", "withdrawn").upcase 
    end
  end

  field :type, ItemTypeEnum, "Publication type; majority are ARTICLE", null: false do
    def resolve(obj, args, ctx) 
      obj = obj.object
      obj.genre == "dissertation" ? "ETD" : obj.genre.upcase.gsub('-','_')
    end
  end

  field :published, String, "Date the item was published", null: false do
    def resolve(obj, args, ctx) 
      obj = obj.object
      obj.published 
    end 
  end

  field :added, DateType, "Date the item was added to eScholarship", null: false do
    def resolve(obj, args, ctx) 
      obj = obj.object
      obj.added 
    end
  end

  field :updated, DateTimeType, "Date and time the item was last updated on eScholarship", null: false do
    def resolve(obj, args, ctx) 
      obj = obj.object
      obj.updated 
    end
  end

  field :permalink, String, "Permanent link to the item on eScholarship", null: false do
    def resolve(obj, args, ctx) 
      obj = obj.object
      "#{ENV['ESCHOL_FRONTEND_URL']}/uc/item/#{obj.id.sub(/^qt/,'')}" 
    end
  end

  field :contentType, String, "Main content MIME type (e.g. application/pdf)" do
    def resolve(obj, args, ctx) 
      obj = obj.object
      obj.content_type 
    end
  end

  field :contentLink, String, "Download link for PDF/content file (if applicable)" do
    def resolve(obj, args, ctx) 
      obj = obj.object
      content_prefix = ENV['CLOUDFRONT_PUBLIC_URL'] || Thread.current[:baseURL]
      obj.status == "published" && obj.content_type == "application/pdf" ?
        "#{content_prefix}/content/#{obj.id}/#{obj.id}.pdf" : nil
    end
  end

  field :contentSize, Int, "Size of PDF/content file in bytes (if applicable)" do
    def resolve(obj, args, ctx) 
      obj = obj.object
      (obj.attrs ? JSON.parse(obj.attrs) : {})['content_length']
    end
  end

  field :authors, AuthorsType, "All authors (can be long)" do
    argument :first, Int, default_value: 100, prepare: ->(val, ctx) {
      (val.nil? || (val >= 1 && val <= 500)) or return GraphQL::ExecutionError.new("'first' must be in range 1..500")
      return val
    }
    argument :more, String, required: false
    def resolve(obj, args, ctx) 
      obj = obj.object
      data = AuthorsData.new(args, obj.id)
      data.nodes.then { |nodes|
        nodes && !nodes.empty? ? data : nil
      }
    end
  end

  field :abstract, String, "Abstract (may include embedded HTML formatting tags)" do
    def resolve(obj, args, ctx) 
      obj = obj.object
      field_name = is_withdrawn(obj) ? 'withdrawn_message' : 'abstract'
      (obj.attrs ? JSON.parse(obj.attrs) : {})[field_name]
    end
  end

  field :journal, String, "Journal name" do
    def resolve(obj, args, ctx) 
      obj = obj.object
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
    end
  end

  field :volume, String, "Journal volume number" do
    def resolve(obj, args, ctx)
      obj = obj.object
      if obj.section
        RecordLoader.for(Section).load(obj.section).then { |section|
          RecordLoader.for(Issue).load(section.issue_id).then { |issue|
            issue.volume
          }
        }
      else
        (obj.attrs ? JSON.parse(obj.attrs) : {}).dig('ext_journal', 'volume')
      end
    end
  end

  field :issue, String, "Journal issue number" do
    def resolve(obj, args, ctx) 
      obj = obj.object
      if obj.section
        RecordLoader.for(Section).load(obj.section).then { |section|
          RecordLoader.for(Issue).load(section.issue_id).then { |issue|
            issue.issue
          }
        }
      else
        (obj.attrs ? JSON.parse(obj.attrs) : {}).dig('ext_journal', 'issue')
      end
    end
  end

  field :issn, String, "Journal ISSN" do
    def resolve(obj, args, ctx) 
      obj = obj.object
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
    end
  end

  field :publisher, String, "Publisher of the item (if any)" do
    def resolve(obj, args, ctx) 
      obj = obj.object
      (obj.attrs ? JSON.parse(obj.attrs) : {})['publisher']
    end
  end

  field :proceedings, String, "Proceedings within which item appears (if any)" do
    def resolve(obj, args, ctx) 
      obj = obj.object
      (obj.attrs ? JSON.parse(obj.attrs) : {})['proceedings']
    end
  end

  field :isbn, String, "Book ISBN" do
    def resolve(obj, args, ctx) 
      obj = obj.object
      (obj.attrs ? JSON.parse(obj.attrs) : {})['isbn']
    end
  end

  field :contributors, ContributorsType, "Editors, advisors, etc. (if any)" do
    argument :first, Int, default_value: 100, prepare: ->(val, ctx) {
      (val.nil? || (val >= 1 && val <= 500)) or return GraphQL::ExecutionError.new("'first' must be in range 1..500")
      return val
    }
    argument :more, String, required: false
    def resolve(obj, args, ctx) 
      obj = obj.object
      data = ContributorsData.new(args, obj.id)
      data.nodes.then { |nodes|
        nodes && !nodes.empty? ? data : nil
      }
    end
  end

  field :units, [UnitType], "The series/unit id(s) associated with this item" do
    def resolve(obj, args, ctx) 
      obj = obj.object
      query = UnitItem.where(is_direct: true).order(:item_id, :ordering_of_units).select(:item_id, :unit_id)
      GroupLoader.for(query, :item_id).load(obj.id).then { |unitItems|
        unitItems ? loadFilteredUnits(unitItems.map { |unitItem| unitItem.unit_id }, []) : nil
      }
    end
  end

  field :tags, [String], "Unified disciplines, keywords, grants, etc." do
    def resolve(obj, args, ctx)
      obj = obj.object
      if is_withdrawn(obj)
        nil
      else
        attrs = obj.attrs ? JSON.parse(obj.attrs) : {}
        out = (attrs['disciplines'] || []).map{|s| "discipline:#{s}"} +
              (attrs['keywords'] || []).map{|s| "keyword:#{s}"} +
              (attrs['subjects'] || []).map{|s| "subject:#{s}"} +
              (attrs['grants'] || []).map{|s| "grant:#{s['name']}"} +
              ["source:#{obj.source}"] +
              ["type:#{obj.genre.sub("dissertation", "etd").upcase.gsub('-','_')}"]
        out.empty? ? nil : out
      end
    end
  end

  field :subjects, [String], "Subject terms (unrestricted) applying to this item" do
    def resolve(obj, args, ctx) 
      obj = obj.object
      (obj.attrs ? JSON.parse(obj.attrs) : {})['subjects']
    end
  end

  field :keywords, [String], "Keywords (unrestricted) applying to this item" do
    def resolve(obj, args, ctx) 
      obj = obj.object
      if is_withdrawn(obj)
        nil
      else
        (obj.attrs ? JSON.parse(obj.attrs) : {})['keywords']
      end
    end
  end

  field :disciplines, [String], "Disciplines applying to this item" do
    def resolve(obj, args, ctx)
      obj = obj.object
      (obj.attrs ? JSON.parse(obj.attrs) : {})['disciplines']
    end
  end

  field :grants, [String], "Funding grants linked to this item" do
    def resolve(obj, args, ctx) 
      obj = obj.object
      grants = (obj.attrs ? JSON.parse(obj.attrs) : {})['grants']
      grants ? grants.map { |gr| gr['name'] } : nil
    end
  end

  field :language, String, "Language specification (ISO 639-2 code)" do
    def resolve(obj, args, ctx) 
      obj = obj.object
      (obj.attrs ? JSON.parse(obj.attrs) : {})['language']
    end
  end

  field :embargoExpires, DateType, "Embargo expiration date (if status=EMBARGOED)" do
    def resolve(obj, args, ctx) 
      obj = obj.object
      (obj.attrs ? JSON.parse(obj.attrs) : {})['embargo_date']
    end
  end

  field :rights, String, "License (none, or e.g. https://creativecommons.org/licenses/by-nc/4.0/)" do
    def resolve(obj, args, ctx) 
      obj = obj.object
      obj.rights
    end
  end

  field :fpage, String, "First page (within a larger work like a journal issue)" do
    def resolve(obj, args, ctx) 
      obj = obj.object
      (obj.attrs ? JSON.parse(obj.attrs) : {}).dig('ext_journal', 'fpage')
    end
  end

  field :lpage, String, "Last page (within a larger work like a journal issue)" do
    def resolve(obj, args, ctx) 
      obj = obj.object
      (obj.attrs ? JSON.parse(obj.attrs) : {}).dig('ext_journal', 'lpage')
    end
  end

  field :pagination, String, "Combined first page - last page" do
    def resolve(obj, args, ctx) 
      obj = obj.object
      attrs = obj.attrs ? JSON.parse(obj.attrs) : {}
      fpage = attrs.dig('ext_journal', 'fpage')
      lpage = attrs.dig('ext_journal', 'lpage')
      fpage ? (lpage ? "#{fpage}-#{lpage}" : fpage) : lpage
    end
  end

  field :suppFiles, [SuppFileType], "Supplemental material (if any)" do
    def resolve(obj, args, ctx) 
      obj = obj.object
      supps = (obj.attrs ? JSON.parse(obj.attrs) : {})['supp_files']
      if supps and ! is_withdrawn(obj)
        supps.map { |data| data.merge({item_id: obj.id}) }
      else
        nil
      end
    end
  end

  field :source, String, "Source system within the eScholarship environment", null: false do
    def resolve(obj, args, ctx) 
      obj = obj.object
      obj.source
    end
  end

  field :ucpmsPubType, String, "If publication originated from UCPMS, the type within that system" do
    def resolve(obj, args, ctx) 
      obj = obj.object
      (obj.attrs ? JSON.parse(obj.attrs) : {})['uc_pms_pub_type']
    end
  end

  field :localIDs, [LocalIDType], "Local item identifiers, e.g. DOI, PubMed ID, LBNL, etc." do
    def resolve(obj, args, ctx) 
      obj = obj.object
      attrs = obj.attrs ? JSON.parse(obj.attrs) : {}
      ids = attrs['local_ids'] || []
      attrs['doi'] and ids.unshift({"type" => "doi", "id" => attrs['doi']})
      ids.empty? ? nil : ids
    end
  end

  field :externalLinks, [String], "Published web location(s) external to eScholarshp" do
    def resolve(obj, args, ctx) 
      obj = obj.object
      (obj.attrs ? JSON.parse(obj.attrs) : {})['pub_web_loc']
    end
  end

  field :bookTitle, String, "Title of the book within which this item appears" do
    def resolve(obj, args, ctx) 
      obj = obj.object
      (obj.attrs ? JSON.parse(obj.attrs) : {})['book_title']
    end
  end

  field :nativeFileName, String, "Name of original (pre-PDF-conversion) file" do
    def resolve(obj, args, ctx) 
      obj = obj.object
      (obj.attrs ? JSON.parse(obj.attrs) : {}).dig('native_file', 'name')
    end
  end

  field :nativeFileSize, String, "Size of original (pre-PDF-conversion) file" do
    def resolve(obj, args, ctx) 
      obj = obj.object
      (obj.attrs ? JSON.parse(obj.attrs) : {}).dig('native_file', 'size')
    end
  end

  field :isPeerReviewed, Boolean, "Whether the work has undergone a peer review process" do
    def resolve(obj, args, ctx) 
      obj = obj.object
      if is_withdrawn(obj)
        nil
      else
        !!((obj.attrs ? JSON.parse(obj.attrs) : {})['is_peer_reviewed'])
      end
    end
  end
end

###################################################################################################
class ItemsType < GraphQL::Schema::Object
  graphql_name "Items"
  description "A list of items, possibly very long, with paging capability"

  field :total, Int, "Approximate total items on all pages", null: false do
    def resolve(obj, args, ctx)
      obj = obj.object
      obj.total 
    end
  end

  field :nodes, [ItemType], "Array of the items on this page", null: false do
    def resolve(obj, args, ctx)
      obj = obj.object
      obj.nodes 
    end
  end

  field :more, String, "Opaque cursor string for next page" do
    def resolve(obj, args, ctx) 
      obj = obj.object
      obj.more 
    end
  end
end

###################################################################################################
class ItemsData
  def initialize(args, ctx, unitID: nil, itemID: nil, personID: nil,
                 authorID: nil, authorScheme: nil, authorSubScheme: nil)
    # Query by status, defaulting to PUBLISHED only
    statuses = (args[:include] || ["PUBLISHED"]).map { |statusEnum| statusEnum.downcase }
    query = Item.where(status: statuses)

    # If 'more' was specified, decode it and use all the parameters from the original query
    if args[:more]
      args = JSON.parse(Base64.urlsafe_decode64(args[:more]))
      args[:before] and args[:before] = DateTime.parse(args[:before])
      args[:after] and args[:after] = DateTime.parse(args[:after])
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
    field = args[:order].sub(/_.*/,'').downcase.to_sym
    ascending = (args[:order] =~ /ASC/)
    query = query.order(ascending ? field : Sequel::desc(field),
                        ascending ? :id   : Sequel::desc(:id))

    # Apply limits as specified
    if args[:before]
      # Exclusive ('<'), so that queries like "after: 2018-11-01 before: 2018-12-01" work as user expects.
      query = query.where(Sequel.lit("#{field} < ?", field == :updated ? args[:before] : args[:before].to_date))
    end
    if args[:after]
      # Inclusive ('>='), so that queries like "after: 2018-11-01 before: 2018-12-01" work as user expects.
      query = query.where(Sequel.lit("#{field} >= ?", field == :updated ? args[:after] : args[:after].to_date))
    end

    # Matching on tags if specified
    (args[:tags] || []).each { |tag|
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
    if args[:lastID]
      dir = ascending ? '>' : '<'
      query = query.where(Sequel.lit("#{field} #{dir} ? or (#{field} = ? and id #{dir} ?)",
                                     args[:lastDate], args[:lastDate], args[:lastID]))
    end

    @query = query
    @limit = args[:first].to_i
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
      more = @args.dup
      more[:lastID]   = nodes()[-1].id
      more[:lastDate] = nodes()[-1][@field].iso8601
      return Base64.urlsafe_encode64(more.to_json).gsub('=', '')
    else
      return nil
    end
  end
end


###################################################################################################
class AuthorsData
  attr_accessor :itemID

  def initialize(args, itemID)
    # If 'more' was specified, decode it and use all the parameters from the original query
    @args = args[:more] ? JSON.parse(Base64.urlsafe_decode64(args[:more])) : args.to_h.clone

    # Record the item ID for querying
    @itemID = itemID
  end

  def total
    @total ||= CountLoader.for(ItemAuthor, :item_id).load(@itemID)
  end

  def nodes
    query = ItemAuthor.order(:item_id, :ordering)
    @args[:lastOrd] and query = query.where(Sequel.lit("ordering > ?", @args[:lastOrd]))
    @nodes ||= GroupLoader.for(query, :item_id, @args[:first]).load(@itemID)
  end

  def more
    nodes.then { |arr|
      if arr && arr.length == @args[:first]
        #TBD -MY
        Base64.urlsafe_encode64(@args.merge({lastOrd: arr[-1].ordering}).to_json)
      else
        nil
      end
    }
  end
end




###################################################################################################
class ContributorsData
  def initialize(args, itemID)
    # If 'more' was specified, decode it and use all the parameters from the original query
    @args = args[:more] ? JSON.parse(Base64.urlsafe_decode64(args[:more])) : args.to_h.clone

    # Record the item ID for querying
    @itemID = itemID
  end

  def total
    @total ||= CountLoader.for(ItemContrib, :item_id).load(@itemID)
  end

  def nodes
    query = ItemContrib.order(:item_id, :ordering)
    @args[:lastOrd] and query = query.where(Sequel.lit("ordering > ?", @args[:lastOrd]))
    @nodes ||= GroupLoader.for(query, :item_id, @args[:first]).load(@itemID)
  end

  def more
    nodes.then { |arr|
      if arr && arr.length == @args[:first]
        Base64.urlsafe_encode64(@args.merge({lastOrd: arr[-1].ordering}).to_json)
      else
        nil
      end
    }
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
    args[:more] and args = JSON.parse(Base64.urlsafe_decode64(args[:more]))

    # If this is a type query, restrict to units of that type
    if args[:type]
      query = query.where(type: args[:type].downcase)
    end

    # Record the base query so if 'total' is requested we count without paging
    @baseQuery = query

    # If this is a 'more' query, add extra constraints so we get the next page (that is,
    # starting just after the end of the last page)
    if args[:lastID]
      query = query.where(Sequel.lit("unit_id > ?", args[:lastID]))
    end

    @query = query
    @limit = args[:first].to_i
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
      more = @args.dup
      more[:lastID]   = nodes()[-1].id
      return Base64.urlsafe_encode64(more.to_json).gsub('=', '')
    else
      return nil
    end
  end
end


###################################################################################################
def defineItemsArgs

    argument :first, Integer, default_value: 100,
    description: "Number of results to return (values 1..500 are valid)",
    prepare: ->(val, ctx) {
      (val.nil? || (val >= 1 && val <= 500)) or return GraphQL::ExecutionError.new("'first' must be in range 1..500")
      return val
    }
    argument :more, String, required: false, description: %{Opaque string obtained from the `more` field of a prior result,
                                               and used to fetch the next set of nodes.
                                               Do not specify any other arguments with this one; the string already
                                               encodes the prior set of arguments.}.unindent
    argument :before, DateTimeType, required: false, description: "Return only items *before* this date/time (within the `order` ordering)"
    argument :after, DateTimeType, required: false, description: "Return only items *after* this date/time (within the `order` ordering)"
    argument :include, [ItemStatusEnum], required: false, description: "Include items w/ given status(es). Defaults to PUBLISHED only."
    argument :tags, [String], required: false, description: %{
             Subset items with keyword, subject, discipline, grant, type, and/or source.
             E.g. 'tags: ["keyword=food"]' or 'tags: ["grant:USDOE"]'}.unindent
    argument :order, ItemOrderEnum, default_value: "ADDED_DESC",
           description: %{Sets the ordering of results
                          (and affects interpretation of the `before` and `after` arguments)}
end

###################################################################################################
class AccessQueryType < GraphQL::Schema::Object
  graphql_name "AccessQuery"
  description "The eScholarship access API"

  field :item, ItemType, "Get item's info given its identifier" do 
    argument :id, ID
    argument :scheme, ItemIDSchemeEnum, required: false
    def resolve(obj, args, ctx)
      obj = obj.object 
      scheme = args[:scheme] || "ARK"
      id = args[:id]
      if scheme == "ARK" && id =~ %r{^ark:/13030/(qt\w{8})$}
        return Item[$1]
      elsif scheme == "DOI" && id =~ /^.*?\b(10\..*)$/
        return Item.where(Sequel.lit(%{attrs->>"$.doi" like ?}, "%#{$1}")).first
      elsif %w{LBNL_PUB_ID OA_PUB_ID ARK}.include?(scheme)
        Item.where(Sequel.lit(%{attrs->"$.local_ids" like ?}, "%#{id}%")).limit(100).each { |item|
          attrs = item.attrs ? JSON.parse(item.attrs) : {}
          (attrs[:local_ids] || []).each { |loc|
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
    end
  end
  field :items, ItemsType, "Query a list of all items" do
    defineItemsArgs
    def resolve(obj, args, ctx)
      ItemsData.new(args, ctx) 
    end
  end

  field :unit, UnitType, "Get a unit given its identifier" do
    argument :id, ID
    def resolve(obj, args, ctx) 
      Unit[args[:id]] 
    end
  end

  field :unitsUCPMSList, [UnitType], "Returns the units matching a given list of UCPMS IDs" do
    argument :ucpmsIdList, [Int]
    def resolve(obj, args, ctx) 
      ucpmsIdListString = args[:ucpmsIdList].join(", ")
      Unit.where(Sequel.lit("attrs->>'$.elements_id' IN (#{ucpmsIdListString})"))
    end
  end

  field :rootUnit, UnitType, "The root of the unit hierarchy (eSchol itself)", null: false do
    def resolve(obj, args, ctx) 
      Unit["root"] 
    end
  end

  field :author, AuthorType, "Get an author by ID (scheme optional, defaults to eschol ARK), or email address" do
    argument :id, ID, required: false
    argument :scheme, AuthorIDSchemeEnum, required: false
    argument :subScheme, String, required: false
    argument :email, String, required: false
    def resolve(obj, args, ctx) 
      id, email, scheme, subScheme = args[:id], args[:email], args[:scheme], args[:subScheme]
      if (id && email) || (!id && !email)
        return GraphQL::ExecutionError.new("must specify either 'id' or 'email'")
      elsif args[:id]
        case scheme
          when nil, 'ARK'; person = Person[args[:id]]
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
    end
  end
end
