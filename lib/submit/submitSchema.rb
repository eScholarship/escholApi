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
           'ETD' => 'etd',
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
      np = person[:nameParts]
      # if "organization" is present in nameParts assume this is a corporate author
      # and encode accordingly.  Person authors should have an institution *not* an organization
      if np and np[:organization]
        xml.organization(np[:organization])
      else
        xml.send(authOrEd) {
          if np = person[:nameParts]
            np[:fname] and xml.fname(np[:fname])
            np[:mname] and xml.mname(np[:mname])
            np[:lname] and xml.lname(np[:lname])
            np[:suffix] and xml.suffix(np[:suffix])
            np[:institution] and xml.institution(np[:institution])
          end
          person[:email] and xml.email(person[:email])
          person[:orcid] and xml.identifier(:type => 'ORCID') { |xml| xml.text person[:orcid] }
        }
      end
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
def convertSubjects(uci, subs)
  uci.find!('subjects').build { |xml|
    subs.each { |sub|
      xml.subject sub
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
def validateDataStatement(input)
  d = input[:dataAvailability]
  if d
    if not ["publicRepo", "publicRepoLater", "suppFiles", "withinManuscript", "onRequest", "thirdParty", "notAvail"].include? d
      raise("Invalid data statement type #{d}")
    end
    if d == "publicRepo" and not input[:dataURL]
      raise("missing data URL for data availability type publicRepo")
    end
  end
end

###################################################################################################
def addContent(xml, input)
  xml.file(url: input[:contentLink],
           originalName: input[:contentFileName] || raise("contentFileName required with contentLink"))
end

###################################################################################################
def addSuppFiles(xml, input)
  suppFiles = input[:suppFiles] ? input[:suppFiles] : []
  validateDataStatement(input)
  xml.supplemental {
    input[:dataAvailability] and xml.dataStatement(type:input[:dataAvailability]){
      input[:dataURL] and xml.text input[:dataURL]
    }
    suppFiles.each { |supp|
      xml.file(url:supp[:fetchLink]) {
        xml.originalName supp[:file]
        xml.mimeType supp[:contentType]
        xml.fileSize supp[:size]
        xml.title supp[:title]
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
    when "https://creativecommons.org/publicdomain/zero/1.0/"; "cc0"
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
  uci[:peerReview] = input[:isPeerReviewed] ? "yes" : "no"
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
  input[:subjects] and convertSubjects(uci, input[:subjects])
  uci.find!('rights').content = convertRights(input[:rights])
  input[:grants] and convertFunding(uci, input[:grants])
  uci.find!('customCitation').content = input[:customCitation]

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
      input[:thesisDept] and xml.department(input[:thesisDept])
  }

  # Content and supp files
  if input[:contentLink] || input[:suppFiles]
    uci.find!('content').build { |xml|
      input[:contentLink] and addContent(xml, input)
      (input[:suppFiles] or input[:dataAvailability]) and addSuppFiles(xml, input)
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
  source_url = input[:sourceURL] || "oapolicy.universityofcalifornia.edu"
  replace_verbs = {
    files:    "Redeposited",
    metadata: "Updated",
    rights:   "Rights Updated",
    localIDs:   "Local IDs Updated"
  }
  puts "input is #{input}"
  actionVerb = replace_verbs.fetch(replace, "Deposited")
  comment = "'#{actionVerb} at #{source_url}' "
  Net::SSH.start($submitServer, $submitUser, **$submitSSHOpts) do |ssh|
    # Verify that the ARK isn't a dupe for this publication ID (can happen if old incomplete
    # items aren't properly cleaned up).
    if !replace
      ssh.exec_sc!("/apps/eschol/subi/lib/subiGuts.rb --checkID #{shortArk} " +
                   "#{input[:sourceName]} #{input[:sourceID]}")
      $provisionalIDs.delete(fullArk)
    end

    # Publish the item
    metaText = uci.to_xml(indent:3)
    File.open("/tmp/meta.tmp.xml", "w:UTF-8") { |io|
      io.write(metaText)
    }

    # hashmap referenced below, with --depositItem as default.
    replace_options = {
      files:    "--replaceFiles",
      metadata: "--replaceMetadata",
      rights:   "--replaceRights",
      localIDs:   "--replaceLocalIDs"
    }

    # Call subiGuts with specified options, get stdout.
    out = ssh.exec_sc!("/apps/eschol/subi/lib/subiGuts.rb " +
                 "#{replace_options.fetch(replace, "--depositItem")} " +
                 "#{shortArk} " +
                 "#{comment} " +
                 "#{input[:submitterEmail] || "''" } -", metaText)
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
                   "#{input[:sourceName]} #{input[:sourceID]}")
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
class MintProvisionalIDInput < GraphQL::Schema::InputObject
  graphql_name "MintProvisionalIDInput"
  description "Input for mintProvisionalID"

  argument :sourceName, String, "Source of data that will be deposited (eg. 'elements', 'ojs', etc.)"
  argument :sourceID, String, "Identifier or other identifying information of data within the source system"
end

class MintProvisionalIDOutput < GraphQL::Schema::Object
  graphql_name "MintProvisionalIDOutput"
  description "Output from the mintProvisionalID mutation"
  field :id, ID, "The minted item identifier", null: false do
    def resolve(obj, args, ctx)
      obj = obj.object 
      obj[:id] 
    end 
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
class NamePartsInput < GraphQL::Schema::InputObject
  graphql_name "NamePartsInput"
  description "The name of a person or organization."

  argument :fname, String, "First name / given name", required: false
  argument :lname, String, "Last name / surname", required: false
  argument :mname, String, "Middle name", required: false
  argument :suffix, String, "Suffix (e.g. Ph.D)", required: false
  argument :institution, String, "Institutional affiliation", required: false
  argument :organization, String, "Instead of lname/fname if this is a group/corp", required: false
end

###################################################################################################
class AuthorInput < GraphQL::Schema::InputObject
  graphql_name "AuthorInput"
  description "A single author (can be a person or organization)"

  argument :nameParts, NamePartsInput, "Name of the author"
  argument :email, String, "Email", required: false
  argument :orcid, String, "ORCID identifier", required: false
end

###################################################################################################
class ContributorInput < GraphQL::Schema::InputObject
  graphql_name "ContributorInput"
  description "A single author (can be a person or organization)"

  argument :role, RoleEnum, "Role in which this person or org contributed"
  argument :nameParts, NamePartsInput, "Name of the contributor"
  argument :email, String, "Email", required: false
  argument :orcid, String, "ORCID identifier", required: false
end

###################################################################################################
class SuppFileInput < GraphQL::Schema::InputObject
  graphql_name "SuppFileInput"
  description "A file containing supplemental material for an item"

  argument :file, String, "Name of the file"
  argument :contentType, String, "Content MIME type of file, if known", required: false
  argument :size, Int, "Size of the file in bytes"
  argument :fetchLink, String, "URL from which to fetch the file"
  argument :title, String, "Display title for file", required: false
end

###################################################################################################
class HTMLSuppFileInput < GraphQL::Schema::InputObject
  graphql_name "HTMLSuppFileInput"
  description "An image file that is required to display an HTML content file"

  argument :file, String, "Name of the file"
  argument :fetchLink, String, "URL from which to fetch the file"
end

###################################################################################################
class LocalIDInput < GraphQL::Schema::InputObject
  graphql_name "LocalIDInput"
  description "Local item identifier, e.g. DOI, PubMed ID, LBNL ID, etc."

  argument :id, String, "The identifier string"
  argument :scheme, ItemIDSchemeEnum, "The scheme under which the identifier was minted"
  argument :subScheme, String, "If scheme is OTHER_ID, this will be more specific", required: false
end

###################################################################################################
class GrantInput < GraphQL::Schema::InputObject
  graphql_name "GrantInput"
  description "Name and reference of linked grant funding"

  argument :name, String, "The full name of the agency and grant"
  argument :reference, String, "Reference code of the grant"
end

###################################################################################################
class DepositItemInput < GraphQL::Schema::InputObject
  graphql_name "DepositItemInput"
  description "Information used to create item data"

  argument :id, ID, "Identifier of the item to update/create; omit to mint a new identifier", required: false
  argument :sourceName, String, "Source of data that will be deposited (eg. 'elements', 'ojs', etc.)"
  argument :sourceID, String, "Identifier or other identifying information of data within the source system"
  argument :sourceFeedLink, String, "Original feed data from the source (if any)", required: false
  argument :sourceURL, String, "URL to the source of the deposit", required: false
  argument :submitterEmail, String, "Email address of person performing this submission"
  argument :title, String, "Title of the item (may include embedded HTML formatting tags)"
  argument :type, ItemTypeEnum, "Publication type; majority are ARTICLE"
  argument :published, String, "Date the item was published"
  argument :isPeerReviewed, Boolean, "Whether the work has undergone a peer review process"
  argument :contentLink, String, "Link from which to fetch the content file (must be .pdf, .doc, or .docx)", required: false
  argument :contentVersion, FileVersionEnum, "Version of the content file (e.g. AUTHOR_VERSION)", required: false
  argument :contentFileName, String, "Original name of the content file", required: false
  argument :authors, [AuthorInput], "All authors", required: false
  argument :abstract, String, "Abstract (may include embedded HTML formatting tags)", required: false
  argument :journal, String, "Journal name", required: false
  argument :volume, String, "Journal volume number", required: false
  argument :issue, String, "Journal issue number", required: false
  argument :issueTitle, String, "Title of the issue", required: false
  argument :issueDate, String, "Date of the issue", required: false
  argument :issueDescription, String, "Description of the issue", required: false
  argument :issueCoverCaption, String, "Caption for the issue cover image", required: false
  argument :sectionHeader, String, "Section header", required: false
  argument :orderInSection, Int, "Order of article in section", required: false
  argument :issn, String, "Journal ISSN", required: false
  argument :publisher, String, "Publisher of the item (if any)", required: false
  argument :proceedings, String, "Proceedings within which item appears (if any)", required: false
  argument :isbn, String, "Book ISBN", required: false
  argument :customCitation, String, "Custom citation", required: false
  argument :contributors, [ContributorInput], "Editors, advisors, etc. (if any)", required: false
  argument :units, [String], "The series/unit id(s) associated with this item"
  argument :subjects, [String], "Subject terms (unrestricted) applying to this item", required: false
  argument :keywords, [String], "Keywords (unrestricted) applying to this item", required: false
  argument :disciplines, [String], "Disciplines applying to this item", required: false
  argument :grants, [GrantInput], "Funding grants linked to this item", required: false
  argument :language, String, "Language specification (ISO 639-2 code)", required: false
  argument :embargoExpires, DateType, "Embargo expiration date (if any)", required: false
  argument :rights, String, "License (none, or e.g. https://creativecommons.org/licenses/by-nc/4.0/)", required: false
  argument :fpage, String, "First page (within a larger work like a journal issue)", required: false
  argument :lpage, String, "Last page (within a larger work like a journal issue)", required: false
  argument :suppFiles, [SuppFileInput], "Supplemental material (if any)", required: false
  argument :imgFiles, [HTMLSuppFileInput], "Image files required for HTML display", required: false
  argument :cssFiles, [HTMLSuppFileInput], "CSS files required for HTML display", required: false
  argument :ucpmsPubType, String, "If publication originated from UCPMS, the type within that system", required: false
  argument :localIDs, [LocalIDInput], "Local identifiers, e.g. DOI, PubMed ID, LBNL, etc.", required: false
  argument :externalLinks, [String], "Published web location(s) external to eScholarshp", required: false
  argument :bookTitle, String, "Title of the book within which this item appears", required: false
  argument :pubRelation, PubRelationEnum, "Publication relationship of this item to eScholarship", required: false
  argument :dateSubmitted, String, "Date the article was submitted", required: false
  argument :dateAccepted, String, "Date the article was accepted", required: false
  argument :datePublished, String, "Date the article was published", required: false
  argument :dataAvailability, String, "Data availability statement", required: false
  argument :dataURL, String, "URL to data available in a public repository", required: false
  argument :thesisDept, String, "Department name in thesis submission", required: false
end

class DepositItemOutput < GraphQL::Schema::Object
  graphql_name "DepositItemOutput"
  description "Output from the depositItem mutation"
  field :id, ID, "The (possibly new) item identifier", null: false do
    def resolve(obj, args, ctx)
      obj = obj.object 
      return obj[:id] 
    end
  end
  field :message, String, "Message describing what was done", null: false do
    def resolve(obj, args, ctx) 
      obj = obj.object
      return obj[:message] 
    end
  end
end

###################################################################################################
class ReplaceMetadataInput < GraphQL::Schema::InputObject
  graphql_name "ReplaceMetadataInput"
  description "Information used to update item metadata"

  argument :id, ID, "Identifier of the item to update/create; omit to mint a new identifier"
  argument :sourceName, String, "Source of data that will be deposited (eg. 'elements', 'ojs', etc.)"
  argument :sourceID, String, "Identifier or other identifying information of data within the source system"
  argument :sourceFeedLink, String, "Original feed data from the source (if any)", required: false
  argument :sourceURL, String, "URL to the source of the deposit", required: false
  argument :submitterEmail, String, "email address of person performing this submission"
  argument :title, String, "Title of the item (may include embedded HTML formatting tags)"
  argument :type, ItemTypeEnum, "Publication type; majority are ARTICLE"
  argument :published, String, "Date the item was published"
  argument :isPeerReviewed, Boolean, "Whether the work has undergone a peer review process"
  argument :authors, [AuthorInput], "All authors", required: false
  argument :abstract, String, "Abstract (may include embedded HTML formatting tags)", required: false
  argument :journal, String, "Journal name", required: false
  argument :volume, String, "Journal volume number", required: false
  argument :issue, String, "Journal issue number", required: false
  argument :issueTitle, String, "Title of the issue", required: false
  argument :issueDate, String, "Date of the issue", required: false
  argument :issueDescription, String, "Description of the issue", required: false
  argument :issueCoverCaption, String, "Caption for the issue cover image", required: false
  argument :sectionHeader, String, "Section header", required: false
  argument :orderInSection, Int, "Order of article in section", required: false
  argument :issn, String, "Journal ISSN", required: false
  argument :publisher, String, "Publisher of the item (if any)", required: false
  argument :proceedings, String, "Proceedings within which item appears (if any)", required: false
  argument :isbn, String, "Book ISBN", required: false
  argument :customCitation, String, "Custom citation", required: false
  argument :contributors, [ContributorInput], "Editors, advisors, etc. (if any)", required: false
  argument :units, [String], "The series/unit id(s) associated with this item"
  argument :subjects, [String], "Subject terms (unrestricted) applying to this item", required: false
  argument :keywords, [String], "Keywords (unrestricted) applying to this item", required: false
  argument :disciplines, [String], "Disciplines applying to this item", required: false
  argument :grants, [GrantInput], "Funding grants linked to this item", required: false
  argument :language, String, "Language specification (ISO 639-2 code)", required: false
  argument :embargoExpires, DateType, "Embargo expiration date (if any)", required: false
  argument :rights, String, "License (none, or e.g. https://creativecommons.org/licenses/by-nc/4.0/)", required: false
  argument :fpage, String, "First page (within a larger work like a journal issue)", required: false
  argument :lpage, String, "Last page (within a larger work like a journal issue)", required: false
  argument :ucpmsPubType, String, "If publication originated from UCPMS, the type within that system", required: false
  argument :localIDs, [LocalIDInput], "Local identifiers, e.g. DOI, PubMed ID, LBNL, etc.", required: false
  argument :bookTitle, String, "Title of the book within which this item appears", required: false
  argument :pubRelation, PubRelationEnum, "Publication relationship of this item to eScholarship", required: false
  argument :dateSubmitted, String, "Date the article was submitted", required: false
  argument :dateAccepted, String, "Date the article was accepted", required: false
  argument :datePublished, String, "Date the article was published", required: false
  argument :dataAvailability, String, "Data availability statement", required: false
  argument :dataURL, String, "URL to data available in a public repository", required: false
  argument :thesisDept, String, "Department name in thesis submission", required: false
end

class ReplaceMetadataOutput < GraphQL::Schema::Object
  graphql_name "ReplaceMetadataOutput"
  description "Output from the replaceMetadata mutation"
  field :message, String, "Message describing what was done", null: false do
    def resolve(obj, args, ctx)
      obj = obj.object 
      return obj[:message] 
    end
  end
end

###################################################################################################
class ReplaceFilesInput < GraphQL::Schema::InputObject
  graphql_name "ReplaceFilesInput"
  description "Information used to replace all files (and external links) of an existing item"

  argument :id, ID, "Identifier of the item to update"
  argument :contentLink, String, "Link from which to fetch the content file (must be .pdf, .doc, or .docx)", required: false
  argument :contentVersion, FileVersionEnum, "Version of the content file (e.g. AUTHOR_VERSION)", required: false
  argument :contentFileName, String, "Original name of the content file", required: false
  argument :suppFiles, [SuppFileInput], "Supplemental material (if any)", required: false
  argument :imgFiles, [HTMLSuppFileInput], "Image files required for HTML display", required: false
  argument :cssFiles, [HTMLSuppFileInput], "CSS files required for HTML display", required: false
  argument :externalLinks, [String], "Published web location(s) external to eScholarshp", required: false
end

class ReplaceFilesOutput < GraphQL::Schema::Object
  graphql_name "ReplaceFilesOutput"
  description "Output from the replaceFiles mutation"
  field :message, String, "Message describing what was done", null: false do
    def resolve(obj, args, ctx) 
      obj = obj.object
      return obj[:message] 
    end
  end
end

###################################################################################################
class UpdateRightsInput < GraphQL::Schema::InputObject
  graphql_name "UpdateRightsInput"
  description "Input to the CC License update"

  argument :id, ID, "Identifier of the item to update"
  argument :rights, String, "License (none, or e.g. https://creativecommons.org/licenses/by-nc/4.0/)"
end

class UpdateRightsOutput < GraphQL::Schema::Object
  graphql_name "UpdateRightsOutput"
  description "Output from updateRights mutation"
  field :message, String, "Message describing the outcome", null: false do
    def resolve(obj, args, ctx) 
      obj = obj.object
      return obj[:message] 
    end
  end
end

###################################################################################################
class UpdateLocalIDsInput < GraphQL::Schema::InputObject
  graphql_name "UpdateLocalIDsInput"
  description "Input for updating Local IDs. (Currently implemented for OSTI IDs only)."

  argument :id, ID, "Identifier of the item to update", required: true
  argument :published, String, "Date the item was published"
  argument :localIDs, [LocalIDInput], "Local identifiers, e.g. DOI, PubMed ID, LBNL, etc.", required: true
end

class UpdateLocalIDsOutput < GraphQL::Schema::Object
  graphql_name "UpdateLocalIDsOutput"
  description "Output from updating Local IDs"
  field :message, String, "Message describing the outcome", null: false do
    def resolve(obj, args, ctx) 
      obj = obj.object
      return obj[:message] 
    end
  end
end

###################################################################################################
class WithdrawItemInput < GraphQL::Schema::InputObject
  graphql_name "WithdrawItemInput"
  description "Input to the withdrawItem mutation"

  argument :id, ID, "Identifier of the item to withdraw"
  argument :publicMessage, String, "Public message to display in place of the withdrawn item"
  argument :internalComment, String, "(Optional) Non-public administrative comment (e.g. ticket URL)", required: false
  argument :redirectTo, ID, "(Optional) Identifier of the item to redirect to", required: false
end

class WithdrawItemOutput < GraphQL::Schema::Object
  graphql_name "WithdrawItemOutput"
  description "Output from the withdrawItem mutation"
  field :message, String, "Message describing the outcome", null: false do
    def resolve(obj, args, ctx) 
      obj = obj.object
      return obj[:message] 
    end
  end
end

###################################################################################################
class UpdateIssueInput < GraphQL::Schema::InputObject
  graphql_name "UpdateIssueInput"
  description "input to the update issue mutation"

  argument :journal, String, "Journal id"
  argument :issue, Int, "Issue number"
  argument :volume, Int, "Volume number"
  argument :coverImageURL, String, "Publically available link to the cover image"
  #argument :numbering, !types.Int, "0 = issue, volue, 1 = issue only, 2 = volume only"
end

class UpdateIssueOutput < GraphQL::Schema::Object
  graphql_name "UpdateIssueOutput"
  description "Output from the updateIssue mutation"
  field :message, String, "Message describing the outcome", null: false do
    def resolve(obj, args, ctx) 
      obj = obj.object
      return obj[:message] 
    end
  end
end

###################################################################################################
class SubmitMutationType < GraphQL::Schema::Object
  graphql_name "SubmitMutation"
  description "The eScholarship submission API"

  field :mintProvisionalID, MintProvisionalIDOutput, null: false do
    description "Create a provisional identifier. Only use this if you really need an ID prior to calling depositItem."
    argument :input, MintProvisionalIDInput, "Source name and source id that will be eventually deposited"
    def resolve(obj, args, ctx) 
      Thread.current[:privileged] or halt(403)
      return mintProvisionalID(args[:input])
    end
  end

  field :depositItem, DepositItemOutput, "Create (or replace) an item with all its data", null: false do
    argument :input, DepositItemInput
    def resolve(obj, args, ctx) 
      Thread.current[:privileged] or halt(403)
      return depositItem(args[:input], replace: nil)
    end
  end

  field :replaceMetadata, ReplaceMetadataOutput, "Replace just the metadata of an existing item", null: false do
    argument :input, ReplaceMetadataInput
    def resolve(obj, args, ctx) 
      Thread.current[:privileged] or halt(403)
      return depositItem(args[:input], replace: :metadata)
    end
  end

  field :updateRights, UpdateRightsOutput, "Update the CC License of an eSchol item", null: false do
    argument :input, UpdateRightsInput
    def resolve(obj, args, ctx) 
      Thread.current[:privileged] or halt(403)
      return depositItem(args[:input], replace: :rights)
    end
  end

  field :updateLocalIDs, UpdateLocalIDsOutput, "Add Local IDs to an eSchol item: Currently implemented for OSTI IDs only.", null: false do
    argument :input, UpdateLocalIDsInput
    def resolve(obj, args, ctx) 
      Thread.current[:privileged] or halt(403)
      return depositItem(args[:input], replace: :localIDs)
    end
  end

  field :replaceFiles, ReplaceFilesOutput, "Replace just the files (and external links) of an existing item", null: false do
    argument :input, ReplaceFilesInput
    def resolve(obj, args, ctx) 
      Thread.current[:privileged] or halt(403)
      return depositItem(args[:input], replace: :files)
    end
  end

  field :withdrawItem, WithdrawItemOutput, "Permanently withdraw, and optionally redirect, an existing item", null: false do
    argument :input, WithdrawItemInput
    def resolve(obj, args, ctx) 
      Thread.current[:privileged] or halt(403)
      return withdrawItem(args[:input])
    end
  end

  field :updateIssue, UpdateIssueOutput, "Update issue properties", null: false do
    argument :input, UpdateIssueInput
    def resolve(obj, args, ctx) 
      Thread.current[:privileged] or halt(403)
      return updateIssue(args[:input])
    end
  end

end
