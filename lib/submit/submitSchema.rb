require 'base64'
require 'json'
require 'net/ssh'
require 'unindent'

$submitServer = ENV['SUBMIT_SERVER'] || raise("missing env SUBMIT_SERVER")
$submitUser = ENV['SUBMIT_USER'] || raise("missing env SUBMIT_USER")

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
    result = ssh.exec!("pwd")
    puts "result=#{result.inspect}"
    result2 = ssh.exec!("ls")
    puts "result2=#{result2.inspect}"
  end

  return { id: "some_ark" }
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
  argument :title, !types.String, "Title of the item (may include embedded HTML formatting tags)"
  argument :type, !ItemTypeEnum, "Publication type; majority are ARTICLE"
  argument :published, !types.String, "Date the item was published"
  argument :contentLink, types.String, "Link from which to fetch the content file (must be .pdf, .doc, or .docx)"
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
  argument :units, types[types.String], "The series/unit id(s) associated with this item"
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
      return { id: args[:input][:id] || "newID" }
    }
  end
end
