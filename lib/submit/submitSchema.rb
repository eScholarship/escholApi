require 'base64'
require 'json'
require 'unindent'

$submitServer = ENV['SUBMIT_SERVER'] || raise("missing env SUBMIT_SERVER")
$submitUser = ENV['SUBMIT_USER'] || raise("missing env SUBMIT_USER")

$provisionalIDs = {}

###################################################################################################
# Make a filename from the outside safe for use as a file on our system.
def sanitizeFilename(fn)
  fn.gsub(/[^-A-Za-z0-9_.]/, "_")
end

###################################################################################################
def convertPubType(type)
  return { 'ARTICLE' => 'paper',
           'NON_TEXTUAL' => 'non-textual',
           'MONOGRAPH' => 'monograph',
           'CHAPTER' => 'chapter' }[type] || raise("Invalid pubType #{type.inspect}")
end

###################################################################################################
def convertFileVersion(version)
  return { 'AUTHOR_VERSION' => 'authorVersion',
           'PUBLISHER_VERSION' => 'publisherVersion' }[version] || raise("Invalid fileVersion #{version.inspect}")
end

###################################################################################################
def assignEmbargo(uci, input)
  if !input[:embargoExpires]
    uci.delete('embargoDate')
  elsif uci[:embargoDate] && uci.xpath("source") == 'subi' &&
          (uci[:state] == 'published' || uci.xpath("history/stateChange[@state='published']"))
    # Do not allow embargo of published item to be overridden. Why? Because say somebody edits a
    # record from Subi using Elements -- they may not be aware there was an embargo, and Elements
    # would blithely un-embargo it.
    return
  else
    uci[:embargoDate] = input[:embargoDate]
  end
end

###################################################################################################
def transformPeople(uci, authOrEd, people)
  return if people.empty?
  uci.find!("#{authOrEd}s").rebuild { |xml|
    people.each { |person|
      xml.send(authOrEd) {
        if np = person[:nameParts]
          np[:fname] and xml.fname(np[:fname])
          np[:mname] and xml.lname(np[:mname])
          np[:lname] and xml.lname(np[:lname])
          np[:suffix] and xml.suffix(np[:suffix])
          np[:institution] and xml.institution(np[:institution])
          np[:organization] and xml.organization(np[:organization])
        end
        person[:email] and xml.email(person[:email])
        person[:orcid] and xml.identifier(:type => 'ORCID') { |xml| xml.text person[:orcid] }
      }
    }
  }
end

###################################################################################################
def convertExtent(uci, input)
  uci.find!('extent').rebuild { |xml|
    input[:fpage] and xml.fpage(input[:fpage])
    input[:lpage] and xml.lpage(input[:lpage])
  }
end

###################################################################################################
def convertKeywords(uci, kws)
  uci.find!('keywords').rebuild { |xml|
    kws.each { |kw|
      xml.keyword kw
    }
  }
end

###################################################################################################
def convertFunding(uci, inFunding)
  uci.find!('funding').rebuild { |xml|
    inFunding.each { |name|
      xml.grant(:name => name)
    }
  }
end

###################################################################################################
def assignSeries(xml, units)
  units.each { |id|
    data = apiQuery("unit(id: $unitID) { name type }", { unitID: ["ID!", id] }).dig("unit")
    xml.entity(id: id, entityLabel: data['name'], entityType: data['type'].downcase)
  }
end

###################################################################################################
def convertLocalIDs(uci, contextXML, ids)
  ids.each { |lid|
    case lid[:scheme]
    when 'DOI'
      uci.find!('doi').content = lid[:id]
    when 'LBNL_PUB_ID'
      contextXML.localID(:type => 'lbnl') { contextXML.text(lid[:id]) }
    when 'OA_PUB_ID'
      contextXML.localID(:type => 'oa_harvester') { contextXML.text(lid[:id]) }
    when 'OTHER'
      contextXML.localID(:type => lid[:subScheme]) { contextXML.text(lid[:id]) }
    else
      raise("unrecognized scheme #{lid[:scheme]}")
    end
  }
end

###################################################################################################
def convertExtLinks(xml, links)
  links.each { |url|
    xml.publishedWebLocation(url)
  }
end

###################################################################################################
# Take a PutItemInput and make a UCI record out of it. Note that if you pass existing UCI
# data in, it will be retained if Elements doesn't override it.
# NOTE: UCI in this context means "UC Ingest" format, the internal metadata format for eScholarship.
def uciFromInput(uci, input)

  # Top-level attributes
  ark = input[:id]
  uci[:id] = ark.sub(%r{ark:/?13030/}, '')
  uci[:dateStamp] = DateTime.now.iso8601
  uci[:peerReview] = input['isPeerReviewed'] ? "yes" : "no"
  uci[:state] = uci[:state] || 'new'
  uci[:stateDate] = uci[:stateDate] || DateTime.now.iso8601
  uci[:type] = convertPubType(input[:type])
  #TODO uci[:pubStatus] = convertPubStatus(input[:pubStatus])
  input[:contentVersion] and uci[:externalPubVersion] = convertFileVersion(input[:contentVersion])
  assignEmbargo(uci, input)

  # Author and editor metadata.
  input[:authors] and transformPeople(uci, "author", input[:authors])
  if input[:contributors]
    transformPeople(uci, "editor",  input[:contributors].select { |contr| contr[:role] == 'EDITOR'  })
    transformPeople(uci, "advisor", input[:contributors].select { |contr| contr[:role] == 'ADVISOR' })
  end

  # Other top-level fields
  uci.find!('source').content = input[:sourceName].sub("elements", "oa_harvester")
  uci.find!('title').content = input[:title]
  input[:abstract] and uci.find!('abstract').content = input[:abstract]
  (input[:fpage] || input[:lpage]) and convertExtent(uci, input)
  input[:keywords] and convertKeywords(uci, input[:keywords])
  uci.find!('rights').content = input[:rights] || 'public'
  input[:grants] and convertFunding(metaHash, uci)

  # Things that go inside <context>
  contextEl = uci.find! 'context'
  contextEl.rebuild { |xml|
      assignSeries(xml, input[:units])
      input[:localIDs] and convertLocalIDs(uci, xml, input[:localIDs])  # also fills in top-level doi field
      input[:issn] and xml.issn(input[:issn])
      input[:isbn] and xml.isbn(input[:isbn]) # for books and chapters
      input[:journal] and xml.journal(input[:journal])
      input[:proceedings] and xml.proceedings(input[:proceedings])
      input[:volume] and xml.volume(input[:volume])
      input[:issue] and  xml.issue(input[:issue])
      input[:bookTitle] and xml.bookTitle(input[:bookTitle])  # for chapters
      input[:externalLinks] and convertExtLinks(xml, input[:externalLinks])
      input[:ucpmsPubType] and xml.ucpmsPubType(input[:ucpmsPubType])
  }

  # Things that go inside <history>
  history = uci.find! 'history'
  history[:origin] = input[:sourceName].sub("elements", "oa_harvester")
  history.at("escholPublicationDate") or history.find!('escholPublicationDate').content = Date.today.iso8601
  history.at("submissionDate") or history.find!('submissionDate').content = Date.today.iso8601
  history.find!('originalPublicationDate').content = input[:published]

  # All done.
  return uci
end

###################################################################################################
def putItem(input)
  Thread.current[:privileged] or halt(403)

  # If no ID provided, mint one now
  fullArk = input[:id] ||
            mintProvisionalID({ sourceName: input[:sourceName], sourceID: input[:sourceID] })[:id]
  shortArk = fullArk[/qt\w{8}/]

  if input[:contentLink]
    raise("TODO: process content link #{input[:contentLink]}")
  end

  metaXML = uciFromInput(Nokogiri::XML("<uci:record xmlns:uci='http://www.cdlib.org/ucingest'/>").root, input)

  # Create the UCI metadata file on the submit server
  Net::SSH.start($submitServer, $submitUser) do |ssh|

    # Publish the item
    metaText = metaXML.to_xml(indent:3)
    ssh.exec_sc!("/apps/eschol/subi/lib/subiGuts.rb --depositItem #{shortArk} " +
                 "'Deposited at oapolicy.universityofcalifornia.edu' " +
                 "#{input['submitterEmail']} -", metaText)

    # Claim the provisional ARK if not already done
    ssh.exec_sc!("/apps/eschol/subi/lib/subiGuts.rb --claimID #{shortArk} " +
                 "#{input['sourceName']} #{input['sourceID']}")
    $provisionalIDs.delete(fullArk)

  end

  # All done.
  return { id: fullArk }
end

###################################################################################################
NullQueryType = GraphQL::ObjectType.define do
  name "None"
  description "There is no query API at this endpoint"

  field :null, types.ID do
    resolve -> (obj, args, ctx) { nil }
  end
end

###################################################################################################
MintProvisionalIDInput = GraphQL::InputObjectType.define do
  name "MintProvisionalIDInput"
  description "Input for mintProvisionalID"

  argument :sourceName, !types.String, "Source of data that will be deposited (eg. 'elements', 'ojs', etc.)"
  argument :sourceID, !types.String, "Identifier or other identifying information of data within the source system"
end

MintProvisionalIDOutput = GraphQL::ObjectType.define do
  name "MintProvisionalIDOutput"
  description "Output from the mintProvisionalID mutation"
  field :id, !types.ID, "The minted item identifier" do
    resolve -> (obj, args, ctx) { obj[:id] }
  end
end

###################################################################################################
def mintProvisionalID(input)
  Thread.current[:privileged] or halt(403)

  sourceName, sourceID = input[:sourceName], input[:sourceID]
  Net::SSH.start($submitServer, $submitUser) do |ssh|
    result = ssh.exec_sc!("/apps/eschol/erep/xtf/control/tools/mintArk.py '#{sourceName}' '#{sourceID}' provisional")
    result[:stdout] =~ %r{ark:/?13030/(qt\w{8})} or raise("mintArk failed: #{result}")
    return { id: "ark:/13030/#{$1}" }
  end
end

###################################################################################################
NamePartsInput = GraphQL::InputObjectType.define do
  name "NamePartsInput"
  description "The name of a person or organization."

  argument :fname, types.String, "First name / given name"
  argument :lname, types.String, "Last name / surname"
  argument :mname, types.String, "Middle name"
  argument :suffix, types.String, "Suffix (e.g. Ph.D)"
  argument :institution, types.String, "Institutional affiliation"
  argument :organization, types.String, "Instead of lname/fname if this is a group/corp"
end

###################################################################################################
AuthorInput = GraphQL::InputObjectType.define do
  name "AuthorInput"
  description "A single author (can be a person or organization)"

  argument :nameParts, !NamePartsInput, "Name of the author"
  argument :email, types.String, "Email"
  argument :orcid, types.String, "ORCID identifier"
end

###################################################################################################
ContributorInput = GraphQL::InputObjectType.define do
  name "ContributorInput"
  description "A single author (can be a person or organization)"

  argument :role, !RoleEnum, "Role in which this person or org contributed"
  argument :nameParts, !NamePartsInput, "Name of the contributor"
  argument :email, types.String, "Email"
  argument :orcid, types.String, "ORCID identifier"
end

###################################################################################################
SuppFileInput = GraphQL::InputObjectType.define do
  name "SuppFileInput"
  description "A file containing supplemental material for an item"

  argument :file, !types.String, "Name of the file"
  argument :contentType, types.String, "Content MIME type of file, if known"
  argument :size, !types.Int, "Size of the file in bytes"
  argument :fetchLink, !types.String, "URL from which to fetch the file"
end

###################################################################################################
LocalIDInput = GraphQL::InputObjectType.define do
  name "LocalIDInput"
  description "Local item identifier, e.g. DOI, PubMed ID, LBNL ID, etc."

  argument :id, !types.String, "The identifier string"
  argument :scheme, !ItemIDSchemeEnum, "The scheme under which the identifier was minted"
  argument :subScheme, types.String, "If scheme is OTHER_ID, this will be more specific"
end

###################################################################################################
PutItemInput = GraphQL::InputObjectType.define do
  name "PutItemInput"
  description "Information used to create or update item data"

  argument :id, types.ID, "identifier of the item to update/create; omit to mint a new identifier"
  argument :sourceName, !types.String, "Source of data that will be deposited (eg. 'elements', 'ojs', etc.)"
  argument :sourceID, !types.String, "Identifier or other identifying information of data within the source system"
  argument :submitterEmail, !types.String, "email address of person performing this submission"
  argument :title, !types.String, "Title of the item (may include embedded HTML formatting tags)"
  argument :type, !ItemTypeEnum, "Publication type; majority are ARTICLE"
  argument :published, !types.String, "Date the item was published"
  argument :isPeerReviewed, !types.Boolean, "Whether the work has undergone a peer review process"
  argument :contentLink, types.String, "Link from which to fetch the content file (must be .pdf, .doc, or .docx)"
  argument :contentVersion, FileVersionEnum, "Version of the content file (e.g. AUTHOR_VERSION)"
  argument :authors, types[AuthorInput], "All authors"
  argument :abstract, types.String, "Abstract (may include embedded HTML formatting tags)"
  argument :journal, types.String, "Journal name"
  argument :volume, types.String, "Journal volume number"
  argument :issue, types.String, "Journal issue number"
  argument :issn, types.String, "Journal ISSN"
  argument :publisher, types.String, "Publisher of the item (if any)"
  argument :proceedings, types.String, "Proceedings within which item appears (if any)"
  argument :isbn, types.String, "Book ISBN"
  argument :contributors, types[ContributorInput], "Editors, advisors, etc. (if any)"
  argument :units, !types[types.String], "The series/unit id(s) associated with this item"
  argument :subjects, types[types.String], "Subject terms (unrestricted) applying to this item"
  argument :keywords, types[types.String], "Keywords (unrestricted) applying to this item"
  argument :disciplines, types[types.String], "Disciplines applying to this item"
  argument :grants, types[types.String], "Funding grants linked to this item"
  argument :language, types.String, "Language specification (ISO 639-2 code)"
  argument :embargoExpires, DateType, "Embargo expiration date (if any)"
  argument :rights, types.String, "License (none, or cc-by-nd, etc.)"
  argument :fpage, types.String, "First page (within a larger work like a journal issue)"
  argument :lpage, types.String, "Last page (within a larger work like a journal issue)"
  argument :suppFiles, types[SuppFileInput], "Supplemental material (if any)"
  argument :ucpmsPubType, types.String, "If publication originated from UCPMS, the type within that system"
  argument :localIDs, types[LocalIDInput], "Local identifiers, e.g. DOI, PubMed ID, LBNL, etc."
  argument :externalLinks, types[types.String], "Published web location(s) external to eScholarshp"
  argument :bookTitle, types.String, "Title of the book within which this item appears"
end

PutItemOutput = GraphQL::ObjectType.define do
  name "PutItemOutput"
  description "Output from the mintPermID mutation"
  field :id, !types.ID, "The (possibly new) item identifier" do
    resolve -> (obj, args, ctx) { obj[:id] }
  end
end

###################################################################################################
SubmitMutationType = GraphQL::ObjectType.define do
  name "SubmitMutation"
  description "The eScholarship submission API"

  field :mintProvisionalID, !MintProvisionalIDOutput do
    description "Create a provisional identifier. Only use this if you really need an ID prior to calling putItem."
    argument :input, !MintProvisionalIDInput, "Source name and source id that will be eventually deposited"
    resolve -> (obj, args, ctx) {
      return mintProvisionalID(args[:input])
    }
  end

  field :putItem, !PutItemOutput, "Create (or replace) an item with all its data" do
    argument :input, !PutItemInput
    resolve -> (obj, args, ctx) {
      return putItem(args[:input])
    }
  end
end
