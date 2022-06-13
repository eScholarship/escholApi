require 'base64'
require 'httparty'
require 'json'
require 'unindent'

$submitServer = ENV['SUBMIT_SERVER'] || raise("missing env SUBMIT_SERVER")
$submitUser = ENV['SUBMIT_USER'] || raise("missing env SUBMIT_USER")
$submitSSHKey = (ENV['SUBMIT_SSH_KEY'] || raise("missing env SUBMIT_SSH_KEY")).gsub(/ ([^ ]{10}|----)/, "\n\\1") + "\n"
$submitSSHOpts = { verify_host_key: :never, key_data: [$submitSSHKey] }

$provisionalIDs = {}

###################################################################################################
# Make a filename from the outside safe for use as a file on our system.
def sanitizeFilename(fn)
  fn.gsub(/[^-A-Za-z0-9_.]/, "_")[0,80]
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
def transformPeople(uci, authOrEd, people)
  return if people.empty?
  uci.find!("#{authOrEd}s").build { |xml|
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
  uci.find!('extent').build { |xml|
    input[:fpage] and xml.fpage(input[:fpage])
    input[:lpage] and xml.lpage(input[:lpage])
  }
end

###################################################################################################
def convertKeywords(uci, kws)
  uci.find!('keywords').build { |xml|
    kws.each { |kw|
      xml.keyword kw
    }
  }
end

###################################################################################################
def convertFunding(uci, inFunding)
  uci.find!('funding').build { |xml|
    inFunding.each { |info|
      xml.grant(:name => info[:name], :reference => info[:reference])
    }
  }
end

###################################################################################################
def assignSeries(xml, units)
  units.empty? and raise("at least one unit must be specified")
  units.each { |id|
    data = apiQuery("unit(id: $unitID) { name type }", { unitID: ["ID!", id] }).dig("unit") || raise("Unit not found: #{id}")
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
    when 'OTHER_ID'
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
def addContent(xml, input)
  xml.file(url: input[:contentLink],
           originalName: input[:contentFileName] || raise("contentFileName required with contentLink"))
end

###################################################################################################
def addSuppFiles(xml, input)
  xml.supplemental {
    input[:suppFiles].each { |supp|
      xml.file(url:supp[:fetchLink]) {
        xml.originalName supp[:file]
        xml.mimeType supp[:contentType]
        xml.fileSize supp[:size]
      }
    }
  }
end

###################################################################################################
def convertPubRelation(relation)
  case relation
    when 'INTERNAL_PUB'; "internalPub"
    when 'EXTERNAL_PUB'; "externalPub"
    when 'EXTERNAL_ACCEPT'; "externalAccept"
    else raise("unknown relation value #{relation.inspect}")
  end
end

###################################################################################################
def convertRights(rights)
  case rights
    when "https://creativecommons.org/licenses/by/4.0/";       "cc1"
    when "https://creativecommons.org/licenses/by-sa/4.0/";    "cc2"
    when "https://creativecommons.org/licenses/by-nd/4.0/";    "cc3"
    when "https://creativecommons.org/licenses/by-nc/4.0/";    "cc4"
    when "https://creativecommons.org/licenses/by-nc-sa/4.0/"; "cc5"
    when "https://creativecommons.org/licenses/by-nc-nd/4.0/"; "cc6"
    when nil;                                                  "public"
    else raise("unexpected rights value: #{rights.inspect}")
  end
end

###################################################################################################
# Take a DepositItemInput and make a UCI record out of it. Note that if you pass existing UCI
# data in, it will be retained if Elements doesn't override it.
# NOTE: UCI in this context means "UC Ingest" format, the internal metadata format for eScholarship.
def uciFromInput(input, ark)

  uci = Nokogiri::XML("<uci:record xmlns:uci='http://www.cdlib.org/ucingest'/>").root

  # Top-level attributes
  uci[:id] = ark.sub(%r{ark:/?13030/}, '')
  uci[:dateStamp] = DateTime.now.iso8601
  uci[:peerReview] = input['isPeerReviewed'] ? "yes" : "no"
  uci[:state] = 'new'
  uci[:stateDate] = DateTime.now.iso8601
  input[:type] and uci[:type] = convertPubType(input[:type])
  input[:pubRelation] and uci[:pubStatus] = convertPubRelation(input[:pubRelation])
  input[:contentVersion] and uci[:externalPubVersion] = convertFileVersion(input[:contentVersion])
  input[:embargoExpires] and uci[:embargoDate] = input[:embargoExpires]

  # Special pseudo-field to record feed metadata link
  input[:sourceFeedLink] and uci.find!('feedLink').content = input[:sourceFeedLink]

  # Author and editor metadata.
  input[:authors] and transformPeople(uci, "author", input[:authors])
  if input[:contributors]
    transformPeople(uci, "editor",  input[:contributors].select { |contr| contr[:role] == 'EDITOR'  })
    transformPeople(uci, "advisor", input[:contributors].select { |contr| contr[:role] == 'ADVISOR' })
  end

  # Other top-level fields
  input[:sourceName] and uci.find!('source').content = input[:sourceName].sub("elements", "oa_harvester")
  uci.find!('title').content = input[:title]
  input[:abstract] and uci.find!('abstract').content = input[:abstract]
  (input[:fpage] || input[:lpage]) and convertExtent(uci, input)
  input[:keywords] and convertKeywords(uci, input[:keywords])
  uci.find!('rights').content = convertRights(input[:rights])
  input[:grants] and convertFunding(uci, input[:grants])

  # Things that go inside <context>
  contextEl = uci.find! 'context'
  contextEl.build { |xml|
      input[:units] and assignSeries(xml, input[:units])
      input[:localIDs] and convertLocalIDs(uci, xml, input[:localIDs])  # also fills in top-level doi field
      input[:issn] and xml.issn(input[:issn])
      input[:isbn] and xml.isbn(input[:isbn]) # for books and chapters
      input[:journal] and xml.journal(input[:journal])
      input[:proceedings] and xml.proceedings(input[:proceedings])
      input[:volume] and xml.volume(input[:volume])
      input[:issue] and  xml.issue(input[:issue])
      input[:issueTitle] and xml.issueTitle(input[:issueTitle])
      input[:issueDate] and xml.issueDate(input[:issueDate])
      input[:issueDescription] and xml.issueDescription(input[:issueDescription])
      input[:issueCoverCaption] and xml.issueCoverCaption(input[:issueCoverCaption])
      input[:sectionHeader] and xml.sectionHeader(input[:sectionHeader])
      input[:orderInSection] and xml.publicationOrder(input[:orderInSection])
      input[:bookTitle] and xml.bookTitle(input[:bookTitle])  # for chapters
      input[:externalLinks] and convertExtLinks(xml, input[:externalLinks])
      input[:ucpmsPubType] and xml.ucpmsPubType(input[:ucpmsPubType])
      input[:dateSubmitted] and xml.dateSubmitted(input[:dateSubmitted])
      input[:dateAccepted] and xml.dateAccepted(input[:dateAccepted])
      input[:datePublished] and xml.datePublished(input[:datePublished])
  }

  # Content and supp files
  if input[:contentLink] || input[:suppFiles]
    uci.find!('content').build { |xml|
      input[:contentLink] and addContent(xml, input)
      input[:suppFiles] and addSuppFiles(xml, input)
    }
  end

  # Things that go inside <history>
  history = uci.find! 'history'
  input[:sourceName] and history[:origin] = input[:sourceName].sub("elements", "oa_harvester")
  history.at("escholPublicationDate") or history.find!('escholPublicationDate').content = Date.today.iso8601
  history.at("submissionDate") or history.find!('submissionDate').content = Date.today.iso8601
  history.find!('originalPublicationDate').content = input[:published]

  # All done.
  return uci
end

###################################################################################################
def depositItem(input, replace:)

  # If no ID provided, mint one now
  fullArk = input[:id] ||
            mintProvisionalID({ sourceName: input[:sourceName], sourceID: input[:sourceID] })[:id]
  shortArk = fullArk[/qt\w{8}/]

  # Convert the metadata
  uci = uciFromInput(input, fullArk)

  # Create the UCI metadata file on the submit server
  actionVerb = replace == :files ? "Redeposited" : replace == :metadata ? "Updated" : "Deposited"
  Net::SSH.start($submitServer, $submitUser, **$submitSSHOpts) do |ssh|
    # Verify that the ARK isn't a dupe for this publication ID (can happen if old incomplete
    # items aren't properly cleaned up).
    if !replace
      ssh.exec_sc!("/apps/eschol/subi/lib/subiGuts.rb --checkID #{shortArk} " +
                   "#{input['sourceName']} #{input['sourceID']}")
      $provisionalIDs.delete(fullArk)
    end

    # Publish the item
    metaText = uci.to_xml(indent:3)
    File.open("/tmp/meta.tmp.xml", "w:UTF-8") { |io|
      io.write(metaText)
    }

    out = ssh.exec_sc!("/apps/eschol/subi/lib/subiGuts.rb " +
                 "#{replace == :files ? "--replaceFiles" : replace == :metadata ? "--replaceMetadata" : "--depositItem"} " +
                 "#{shortArk} " +
                 "'#{actionVerb} at oapolicy.universityofcalifornia.edu' " +
                 "#{input['submitterEmail'] || "''" } -", metaText)
    puts "stdout from main subiGuts operation:\n#{out[:stdout]}"

    if input.key?(:imgFiles)
      imgs = JSON.generate(input[:imgFiles].map{ |i|
          {"file": i[:file], "fetchLink": i[:fetchLink]}
        })
      out = ssh.exec_sc!("/apps/eschol/subi/lib/subiGuts.rb --uploadImages #{shortArk} '#{imgs}'")
      puts "stdout from uploadImages:\n#{out[:stdout]}"
    end

    if input.key?(:cssFiles)
      css = JSON.generate(input[:cssFiles].map{ |i|
          {"file": i[:file], "fetchLink": i[:fetchLink]}
        })
      out = ssh.exec_sc!("/apps/eschol/subi/lib/subiGuts.rb --uploadImages #{shortArk} '#{css}'")
      puts "stdout from uploadImages:\n#{out[:stdout]}"
    end

    # Claim the provisional ARK if not already done
    if !replace
      ssh.exec_sc!("/apps/eschol/subi/lib/subiGuts.rb --claimID #{shortArk} " +
                   "#{input['sourceName']} #{input['sourceID']}")
      $provisionalIDs.delete(fullArk)
    end
  end

  # All done.
  return { id: fullArk, message: actionVerb + "." }
end

###################################################################################################
def bashEscape(str)
  # See the second answer at: https://stackoverflow.com/questions/6306386/
  return "'#{str.gsub("'", "'\\\\''")}'"    # gsub: "\\\\" in makes one "\" out
end

###################################################################################################
def withdrawItem(input)

  # Grab the ID
  shortArk = input[:id][/qt\w{8}/] or return GraphQL::ExecutionError.new("invalid id")

  # Do the pairtree work on the submit server
  Net::SSH.start($submitServer, $submitUser, **$submitSSHOpts) do |ssh|
    cmd = "/apps/eschol/erep/xtf/control/tools/withdrawItem.py -yes "
    cmd += "-m #{bashEscape(input[:publicMessage])} "
    input[:internalComment] and cmd += "-i #{bashEscape(input[:internalComment])} "
    cmd += bashEscape(shortArk)
    result = ssh.exec_sc!(cmd)
    result[:stdout] =~ %r{withdrawn}i or return GraphQL::ExecutionError.new("withdrawItem.py failed: #{result}")

    ssh.exec_sc!("cd /apps/eschol/eschol5/jschol && " +
                 "source ./config/env.sh && " +
                 "./tools/convert.rb --preindex #{shortArk}")
  end

  # Insert a redirect record if requested
  if input[:redirectTo]
    shortRedirectTo = input[:redirectTo][/qt\w{8}/] or return GraphQL::ExecutionError.new("invalid redirectTo id")
    Redirect.create(
      :kind      => 'item',
      :from_path => "/uc/item/#{shortArk.sub(/^qt/,'')}",
      :to_path   => "/uc/item/#{shortRedirectTo.sub(/^qt/,'')}",
      :descrip   => input[:internalComment]
    )
  end

  # All done.
  return { message: "Withdrawn" }
end

###################################################################################################
def updateIssue(input)
  # identification information
  journal = input[:journal]
  issue = input[:issue]
  volume = input[:volume]

  coverImageURL = input[:coverImageURL]

  # put the cover image up there
  Net::SSH.start($submitServer, $submitUser, **$submitSSHOpts) do |ssh|
    cmd = "/apps/eschol/subi/lib/subiGuts.rb --uploadIssueCoverImage #{journal} #{issue} #{volume} #{coverImageURL}"
    out = ssh.exec_sc!(cmd)
    puts "stdout from uploadIssueCoverImage:\n#{out[:stdout]}"
  end

  # All done.
  return { message: "Cover Image uploaded" }
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
  sourceName, sourceID = input[:sourceName], input[:sourceID]
  Net::SSH.start($submitServer, $submitUser, **$submitSSHOpts) do |ssh|
    result = ssh.exec_sc!("/apps/eschol/erep/xtf/control/tools/mintArk.py '#{sourceName}' '#{sourceID}' provisional")
    result[:stdout] =~ %r{(qt\w{8})} or raise("mintArk failed: #{result}")
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
HTMLSuppFileInput = GraphQL::InputObjectType.define do
  name "HTMLSuppFileInput"
  description "An image file that is required to display an HTML content file"

  argument :file, !types.String, "Name of the file"
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
GrantInput = GraphQL::InputObjectType.define do
  name "GrantInput"
  description "Name and reference of linked grant funding"

  argument :name, !types.String, "The full name of the agency and grant"
  argument :reference, !types.String, "Reference code of the grant"
end

###################################################################################################
DepositItemInput = GraphQL::InputObjectType.define do
  name "DepositItemInput"
  description "Information used to create item data"

  argument :id, types.ID, "Identifier of the item to update/create; omit to mint a new identifier"
  argument :sourceName, !types.String, "Source of data that will be deposited (eg. 'elements', 'ojs', etc.)"
  argument :sourceID, !types.String, "Identifier or other identifying information of data within the source system"
  argument :sourceFeedLink, types.String, "Original feed data from the source (if any)"
  argument :submitterEmail, !types.String, "Email address of person performing this submission"
  argument :title, !types.String, "Title of the item (may include embedded HTML formatting tags)"
  argument :type, !ItemTypeEnum, "Publication type; majority are ARTICLE"
  argument :published, !types.String, "Date the item was published"
  argument :isPeerReviewed, !types.Boolean, "Whether the work has undergone a peer review process"
  argument :contentLink, types.String, "Link from which to fetch the content file (must be .pdf, .doc, or .docx)"
  argument :contentVersion, FileVersionEnum, "Version of the content file (e.g. AUTHOR_VERSION)"
  argument :contentFileName, types.String, "Original name of the content file"
  argument :authors, types[AuthorInput], "All authors"
  argument :abstract, types.String, "Abstract (may include embedded HTML formatting tags)"
  argument :journal, types.String, "Journal name"
  argument :volume, types.String, "Journal volume number"
  argument :issue, types.String, "Journal issue number"
  argument :issueTitle, types.String, "Title of the issue"
  argument :issueDate, types.String, "Date of the issue"
  argument :issueDescription, types.String, "Description of the issue"
  argument :issueCoverCaption, types.String, "Caption for the issue cover image"
  argument :sectionHeader, types.String, "Section header"
  argument :orderInSection, types.Int, "Order of article in section"
  argument :issn, types.String, "Journal ISSN"
  argument :publisher, types.String, "Publisher of the item (if any)"
  argument :proceedings, types.String, "Proceedings within which item appears (if any)"
  argument :isbn, types.String, "Book ISBN"
  argument :contributors, types[ContributorInput], "Editors, advisors, etc. (if any)"
  argument :units, !types[types.String], "The series/unit id(s) associated with this item"
  argument :subjects, types[types.String], "Subject terms (unrestricted) applying to this item"
  argument :keywords, types[types.String], "Keywords (unrestricted) applying to this item"
  argument :disciplines, types[types.String], "Disciplines applying to this item"
  argument :grants, types[GrantInput], "Funding grants linked to this item"
  argument :language, types.String, "Language specification (ISO 639-2 code)"
  argument :embargoExpires, DateType, "Embargo expiration date (if any)"
  argument :rights, types.String, "License (none, or e.g. https://creativecommons.org/licenses/by-nc/4.0/)"
  argument :fpage, types.String, "First page (within a larger work like a journal issue)"
  argument :lpage, types.String, "Last page (within a larger work like a journal issue)"
  argument :suppFiles, types[SuppFileInput], "Supplemental material (if any)"
  argument :imgFiles, types[HTMLSuppFileInput], "Image files required for HTML display"
  argument :cssFiles, types[HTMLSuppFileInput], "CSS files required for HTML display"
  argument :ucpmsPubType, types.String, "If publication originated from UCPMS, the type within that system"
  argument :localIDs, types[LocalIDInput], "Local identifiers, e.g. DOI, PubMed ID, LBNL, etc."
  argument :externalLinks, types[types.String], "Published web location(s) external to eScholarshp"
  argument :bookTitle, types.String, "Title of the book within which this item appears"
  argument :pubRelation, PubRelationEnum, "Publication relationship of this item to eScholarship"
  argument :dateSubmitted, types.String, "Date the article was submitted"
  argument :dateAccepted, types.String, "Date the article was accepted"
  argument :datePublished, types.String, "Date the article was published"
end

DepositItemOutput = GraphQL::ObjectType.define do
  name "DepositItemOutput"
  description "Output from the depositItem mutation"
  field :id, !types.ID, "The (possibly new) item identifier" do
    resolve -> (obj, args, ctx) { return obj[:id] }
  end
  field :message, !types.String, "Message describing what was done" do
    resolve -> (obj, args, ctx) { return obj[:message] }
  end
end

###################################################################################################
ReplaceMetadataInput = GraphQL::InputObjectType.define do
  name "ReplaceMetadataInput"
  description "Information used to update item metadata"

  argument :id, !types.ID, "Identifier of the item to update/create; omit to mint a new identifier"
  argument :sourceName, !types.String, "Source of data that will be deposited (eg. 'elements', 'ojs', etc.)"
  argument :sourceID, !types.String, "Identifier or other identifying information of data within the source system"
  argument :sourceFeedLink, types.String, "Original feed data from the source (if any)"
  argument :submitterEmail, !types.String, "email address of person performing this submission"
  argument :title, !types.String, "Title of the item (may include embedded HTML formatting tags)"
  argument :type, !ItemTypeEnum, "Publication type; majority are ARTICLE"
  argument :published, !types.String, "Date the item was published"
  argument :isPeerReviewed, !types.Boolean, "Whether the work has undergone a peer review process"
  argument :authors, types[AuthorInput], "All authors"
  argument :abstract, types.String, "Abstract (may include embedded HTML formatting tags)"
  argument :journal, types.String, "Journal name"
  argument :volume, types.String, "Journal volume number"
  argument :issue, types.String, "Journal issue number"
  argument :issueTitle, types.String, "Title of the issue"
  argument :issueDate, types.String, "Date of the issue"
  argument :issueDescription, types.String, "Description of the issue"
  argument :issueCoverCaption, types.String, "Caption for the issue cover image"
  argument :sectionHeader, types.String, "Section header"
  argument :orderInSection, types.Int, "Order of article in section"
  argument :issn, types.String, "Journal ISSN"
  argument :publisher, types.String, "Publisher of the item (if any)"
  argument :proceedings, types.String, "Proceedings within which item appears (if any)"
  argument :isbn, types.String, "Book ISBN"
  argument :contributors, types[ContributorInput], "Editors, advisors, etc. (if any)"
  argument :units, !types[types.String], "The series/unit id(s) associated with this item"
  argument :subjects, types[types.String], "Subject terms (unrestricted) applying to this item"
  argument :keywords, types[types.String], "Keywords (unrestricted) applying to this item"
  argument :disciplines, types[types.String], "Disciplines applying to this item"
  argument :grants, types[GrantInput], "Funding grants linked to this item"
  argument :language, types.String, "Language specification (ISO 639-2 code)"
  argument :embargoExpires, DateType, "Embargo expiration date (if any)"
  argument :rights, types.String, "License (none, or e.g. https://creativecommons.org/licenses/by-nc/4.0/)"
  argument :fpage, types.String, "First page (within a larger work like a journal issue)"
  argument :lpage, types.String, "Last page (within a larger work like a journal issue)"
  argument :ucpmsPubType, types.String, "If publication originated from UCPMS, the type within that system"
  argument :localIDs, types[LocalIDInput], "Local identifiers, e.g. DOI, PubMed ID, LBNL, etc."
  argument :bookTitle, types.String, "Title of the book within which this item appears"
  argument :pubRelation, PubRelationEnum, "Publication relationship of this item to eScholarship"
  argument :dateSubmitted, types.String, "Date the article was submitted"
  argument :dateAccepted, types.String, "Date the article was accepted"
  argument :datePublished, types.String, "Date the article was published"
end

ReplaceMetadataOutput = GraphQL::ObjectType.define do
  name "ReplaceMetadataOutput"
  description "Output from the replaceMetadata mutation"
  field :message, !types.String, "Message describing what was done" do
    resolve -> (obj, args, ctx) { return obj[:message] }
  end
end

###################################################################################################
ReplaceFilesInput = GraphQL::InputObjectType.define do
  name "ReplaceFilesInput"
  description "Information used to replace all files (and external links) of an existing item"

  argument :id, !types.ID, "Identifier of the item to update"
  argument :contentLink, types.String, "Link from which to fetch the content file (must be .pdf, .doc, or .docx)"
  argument :contentVersion, FileVersionEnum, "Version of the content file (e.g. AUTHOR_VERSION)"
  argument :contentFileName, types.String, "Original name of the content file"
  argument :suppFiles, types[SuppFileInput], "Supplemental material (if any)"
  argument :imgFiles, types[HTMLSuppFileInput], "Image files required for HTML display"
  argument :cssFiles, types[HTMLSuppFileInput], "CSS files required for HTML display"
  argument :externalLinks, types[types.String], "Published web location(s) external to eScholarshp"
end

ReplaceFilesOutput = GraphQL::ObjectType.define do
  name "ReplaceFilesOutput"
  description "Output from the replaceFiles mutation"
  field :message, !types.String, "Message describing what was done" do
    resolve -> (obj, args, ctx) { return obj[:message] }
  end
end

###################################################################################################
WithdrawItemInput = GraphQL::InputObjectType.define do
  name "WithdrawItemInput"
  description "Input to the withdrawItem mutation"

  argument :id, !types.ID, "Identifier of the item to withdraw"
  argument :publicMessage, !types.String, "Public message to display in place of the withdrawn item"
  argument :internalComment, types.String, "(Optional) Non-public administrative comment (e.g. ticket URL)"
  argument :redirectTo, types.ID, "(Optional) Identifier of the item to redirect to"
end

WithdrawItemOutput = GraphQL::ObjectType.define do
  name "WithdrawItemOutput"
  description "Output from the withdrawItem mutation"
  field :message, !types.String, "Message describing the outcome" do
    resolve -> (obj, args, ctx) { return obj[:message] }
  end
end

###################################################################################################
UpdateIssueInput = GraphQL::InputObjectType.define do
  name "UpdateIssueInput"
  description "input to the update issue mutation"

  argument :journal, !types.String, "Journal id"
  argument :issue, !types.Int, "Issue number"
  argument :volume, !types.Int, "Volume number"
  argument :coverImageURL, !types.String, "Publically available link to the cover image"
  #argument :numbering, !types.Int, "0 = issue, volue, 1 = issue only, 2 = volume only"
end

UpdateIssueOutput = GraphQL::ObjectType.define do
  name "UpdateIssueOutput"
  description "Output from the updateIssue mutation"
  field :message, !types.String, "Message describing the outcome" do
    resolve -> (obj, args, ctx) { return obj[:message] }
  end
end

###################################################################################################
SubmitMutationType = GraphQL::ObjectType.define do
  name "SubmitMutation"
  description "The eScholarship submission API"

  field :mintProvisionalID, !MintProvisionalIDOutput do
    description "Create a provisional identifier. Only use this if you really need an ID prior to calling depositItem."
    argument :input, !MintProvisionalIDInput, "Source name and source id that will be eventually deposited"
    resolve -> (obj, args, ctx) {
      Thread.current[:privileged] or halt(403)
      return mintProvisionalID(args[:input])
    }
  end

  field :depositItem, !DepositItemOutput, "Create (or replace) an item with all its data" do
    argument :input, !DepositItemInput
    resolve -> (obj, args, ctx) {
      Thread.current[:privileged] or halt(403)
      return depositItem(args[:input], replace: nil)
    }
  end

  field :replaceMetadata, !ReplaceMetadataOutput, "Replace just the metadata of an existing item" do
    argument :input, !ReplaceMetadataInput
    resolve -> (obj, args, ctx) {
      Thread.current[:privileged] or halt(403)
      return depositItem(args[:input], replace: :metadata)
    }
  end

  field :replaceFiles, !ReplaceFilesOutput, "Replace just the files (and external links) of an existing item" do
    argument :input, !ReplaceFilesInput
    resolve -> (obj, args, ctx) {
      Thread.current[:privileged] or halt(403)
      return depositItem(args[:input], replace: :files)
    }
  end

  field :withdrawItem, !WithdrawItemOutput, "Permanently withdraw, and optionally redirect, an existing item" do
    argument :input, !WithdrawItemInput
    resolve -> (obj, args, ctx) {
      Thread.current[:privileged] or halt(403)
      return withdrawItem(args[:input])
    }
  end

  field :updateIssue, !UpdateIssueOutput, "Update issue properties" do
    argument :input, !UpdateIssueInput
    resolve -> (obj, args, ctx) {
      Thread.current[:privileged] or halt(403)
      return updateIssue(args[:input])
    }
  end
end
