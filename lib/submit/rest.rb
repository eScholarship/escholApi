# A DSpace wrapper around escholarship, used to integrate eschol content into Symplectic Elements

require 'cgi'
require 'digest'
require 'erubis'
require 'securerandom'
require 'xmlsimple'

$jscholKey = ENV['JSCHOL_KEY'] or raise("missing env JSCHOL_KEY")

$sessions = {}
MAX_SESSIONS = 5

$userErrors = {}
MAX_USER_ERRORS = 40

$recentArkInfo = {}
MAX_RECENT_ARK_INFO = 20

$nextMoreToken = {}
MAX_NEXT_MORE_TOKEN = 20

$privApiKey = ENV['ESCHOL_PRIV_API_KEY'] or raise("missing env ESCHOL_PRIV_API_KEY")

$rt2Email = ENV['RT2_DSPACE_EMAIL'] or raise("missing env RT2_DSPACE_EMAIL")
$rt2Password = ENV['RT2_DSPACE_PASSWORD'] or raise("missing env RT2_DSPACE_PASSWORD")

###################################################################################################
ITEM_FIELDS = %{
  id
  title
  authors {
    nodes {
      email
      orcid
      nameParts {
        fname
        mname
        lname
        suffix
        institution
        organization
      }
    }
  }
  contributors {
    nodes {
      role
      email
      nameParts {
        fname
        mname
        lname
        suffix
        institution
        organization
      }
    }
  }
  localIDs {
    id
    scheme
    subScheme
  }
  units {
    id
    name
    parents {
      name
    }
    items {
      total
    }
  }
  abstract
  added
  bookTitle
  contentLink
  contentType
  contentSize
  disciplines
  embargoExpires
  externalLinks
  pagination
  grants
  issn
  isbn
  journal
  issue
  volume
  keywords
  publisher
  published
  language
  permalink
  proceedings
  published
  rights
  source
  status
  subjects
  title
  type
  ucpmsPubType
  updated
  nativeFileName
  nativeFileSize
  suppFiles {
    file
    size
    contentType
  }
}

###################################################################################################
# Nice way to generate XML, just using ERB-like templates instead of Builder's weird syntax.
def xmlGen(templateStr, bnding, xml_header: true)
  $templates ||= {}
  template = ($templates[templateStr] ||= XMLGen.new(templateStr))
  doc = Nokogiri::XML(template.result(bnding), nil, "UTF-8", &:noblanks)
  return xml_header ? doc.to_xml : doc.root.to_xml
end
class XMLGen < Erubis::Eruby
  include Erubis::EscapeEnhancer
end

#################################################################################################
# Send a GraphQL query to the eschol API, returning the JSON results.
def apiQuery(query, vars = {}, privileged = false)
  if vars.empty?
    query = "query { #{query} }"
  else
    query = "query(#{vars.map{|name, pair| "$#{name}: #{pair[0]}"}.join(", ")}) { #{query} }"
  end
  varHash = Hash[vars.map{|name,pair| [name.to_s, pair[1]]}]
  headers = { 'Content-Type' => 'application/json' }
  privKey = ENV['ESCHOL_PRIV_API_KEY'] or raise("missing env ESCHOL_PRIV_API_KEY")
  privileged and headers['Privileged'] = privKey
  response = HTTParty.post("#{$escholServer}/graphql",
               :headers => headers,
               :body => { variables: varHash, query: query }.to_json)
  response['errors'] and raise("Internal error (graphql): #{response['errors'][0]['message']}")
  response['data']
end

###################################################################################################
def getSession
  if request.env['HTTP_COOKIE'] =~ /JSESSIONID=(\w{32})/
    session = $1
    if $sessions.include?(session)
      puts "Got existing session: #{session}"
      return session
    end
  end

  session = SecureRandom.hex(16).upcase
  $sessions.size >= MAX_SESSIONS and $sessions.shift
  $sessions[session] = { time: Time.now, loggedIn: false }
  headers 'Set-Cookie' => "JSESSIONID=#{session}; Path=/dspace-rest"
  puts "Created new session: #{session}"
  return session
end

###################################################################################################
get "/dspace-rest/status" do
  content_type "text/xml"
  if $sessions[getSession][:loggedIn]
    xmlGen('''
      <status>
        <authenticated>true</authenticated>
        <email><%=email%></email>
        <fullname>DSpace user</fullname>
        <okay>true</okay>
      </status>''', {email: $rt2email})
  else
    xmlGen('''
      <status>
        <apiVersion>6.3</apiVersion>
        <authenticated>false</authenticated>
        <okay>true</okay>
        <sourceVersion>6.3</sourceVersion>
      </status>''', {})
  end
end

###################################################################################################
post "/dspace-rest/login" do
  content_type "text/plain;charset=utf-8"
  puts "expecting email #{$rt2Email.inspect} and pw #{$rt2Password.inspect}"
  params['email'] == $rt2Email && params['password'] == $rt2Password or halt(401, "Unauthorized.\n")
  $sessions[getSession][:loggedIn] = true
  puts "==> Login ok, setting flag on session."
  "OK\n"
end

###################################################################################################
def verifyLoggedIn
  puts "Verifying login, cookie=#{request.env['HTTP_COOKIE']}"
  $sessions[getSession][:loggedIn] or halt(401, "Unauthorized.\n")
end

###################################################################################################
get "/dspace-rest/collections" do
  verifyLoggedIn
  content_type "text/xml"
  inner = %w{cdl_rw iis_general jtest root}.map { |unitID|
    data = apiQuery("unit(id: $unitID) { items { total } }", { unitID: ["ID!", unitID] }).dig("unit")
    xmlGen('''
      <collection>
        <link>/rest/collections/13030/<%= unitID %></link>
        <expand>parentCommunityList</expand>
        <expand>parentCommunity</expand>
        <expand>items</expand>
        <expand>license</expand>
        <expand>logo</expand>
        <expand>all</expand>
        <handle>13030/<%= unitID %></handle>
        <name><%= unitID %></name>
        <type>collection</type>
        <UUID><%= unitID %></UUID>
        <copyrightText/>
        <introductoryText/>
        <numberItems><%= data.dig("items", "total") %></numberItems>
        <shortDescription><%= unitID %></shortDescription>
        <sidebarText/>
      </collection>''', binding, xml_header: false)
  }
  xmlGen('''
    <collections>
      <%== inner.join("\n") %>
    </collections>
  ''', binding)
end

###################################################################################################
def stripHTML(encoded)
  encoded.gsub("&amp;lt;", "&lt;").gsub("&amp;gt;", "&gt;").gsub(%r{&lt;/?\w+?&gt;}, "")
end

###################################################################################################
def calcContentReadKey(itemID, contentPath)
  key = Digest::SHA1.hexdigest($jscholKey + "|read|" + contentPath).to_i(16).to_s(36)
end

###################################################################################################
def filePreviewLink(itemID, contentPath)
  server = "https://#{request.host}"
  key = calcContentReadKey(itemID, contentPath)
  return "#{server}/dspace-preview/#{itemID}/#{contentPath}?key=#{key}"
end

###################################################################################################
def formatItemData(data, expand)
  data.delete_if{ |k,v| v.nil? || (v.respond_to?(:empty) && v.empty?) }
  itemID = data['id'] or raise("expected to get item ID")
  itemID.sub!("ark:/13030/", "")

  if expand =~ /metadata/
    metaXML = stripHTML(XmlSimple.xml_out(data, {suppress_empty: nil, noattr: true, rootname: "metadata"}))
  else
    metaXML = ""
  end
  lastMod = Time.parse(data.dig("updated")).strftime("%Y-%m-%d %H:%M:%S")

  if expand =~ /parentCollection/
    collections = (data['units'] || []).map { |unit|
      parentName = unit.dig("parents", 0, "name")
      fullUnitName = parentName ? "#{parentName}: #{unit["name"]}" : unit["name"]
      xmlGen('''
        <parentCollection>
          <link>/rest/collections/13030/<%= unit["id"] %></link>
          <expand>parentCommunityList</expand>
          <expand>parentCommunity</expand>
          <expand>items</expand>
          <expand>license</expand>
          <expand>logo</expand>
          <expand>all</expand>
          <handle>13030/<%= unit["id"] %></handle>
          <name><%= fullUnitName %></name>
          <type>collection</type>
          <UUID><%= unit["id"] %></UUID>
          <copyrightText/>
          <introductoryText/>
          <numberItems><%= unit.dig("items", "total") %></numberItems>
          <shortDescription><%= unit["id"] %></shortDescription>
          <sidebarText/>
        </parentCollection>''', binding, xml_header: false)
    }.join("\n")
  else
    collections = ""
  end

  if expand =~ /bitstreams/
    arr = []
    if data['contentLink'] && data['contentType'] == "application/pdf"
      if data['nativeFileName']
        arr << { id: "#{itemID}/content/#{data['nativeFileName']}",
                 name: data['nativeFileName'], size: data['nativeFileSize'],
                 link: filePreviewLink(itemID, "content/#{CGI.escape(data['nativeFileName'])}"),
                 type: data['contentType'] }
      else
        arr << { id: "#{itemID}/content/#{itemID}.pdf",
                 name: "#{itemID}.pdf", size: data['contentSize'],
                 link: filePreviewLink(itemID, "content/#{itemID}.pdf"),
                 type: data['contentType'] }
      end
    end
    (data['suppFiles'] || []).each { |supp|
        arr << { id: "#{itemID}/content/supp/#{CGI.escape(supp['file'])}",
                 name: supp['file'], size: supp['size'],
                 link: filePreviewLink(itemID, "content/supp/#{CGI.escape(supp['file'])}"),
                 type: supp['contentType'] }
    }
    bitstreams = arr.map.with_index { |info, idx|
      # Yes, it's wierd, but DSpace generates one <bitstreams> (plural) element for each bitstream.
      # Maybe somebody would have noticed this if they had bothered documenting their API.
      xmlGen('''
        <bitstreams>
          <link><%= info[:link] %></link>
          <expand>parent</expand>
          <expand>policies</expand>
          <expand>all</expand>
          <name><%= info[:name] %></name>
          <type>bitstream</type>
          <UUID><%= info[:id] %></UUID>
          <bundleName>ORIGINAL</bundleName>
          <description>File</description>
          <format>File</format>
          <mimeType><%= info[:type] %></mimeType>
          <retrieveLink><%= info[:link] %></retrieveLink>
          <sequenceId><%= idx+1 %></sequenceId>
          <sizeBytes><%= info[:size] %></sizeBytes>
        </bitstreams>''', binding, xml_header: false)
    }.join("\n")
  end

  return xmlGen('''
    <item>
      <link>/rest/items/13030/<%= itemID %></link>
      <expand>parentCommunityList</expand>
      <expand>all</expand>
      <handle>13030/<%= itemID %></handle>
      <name><%= data["title"] %></name>
      <type>item</type>
      <UUID><%= itemID %></UUID>
      <archived>true</archived>
      <%== metaXML %>
      <lastModified><%= lastMod %></lastModified>
      <%== collections %>
      <%== collections.gsub("parentCollection", "parentCollectionList") %>
      <withdrawn><%= data.dig("status") == "WITHDRAWN" %></withdrawn>
      <%== bitstreams %>
    </item>''', binding, xml_header: false)
end

###################################################################################################
get %r{/dspace-rest/(items|handle)/(.*)} do
  verifyLoggedIn
  request.path =~ /(qt\w{8})/ or halt(404, "Invalid item ID")
  itemID = $1
  content_type "text/xml"
  data = apiQuery("item(id: $itemID) { #{ITEM_FIELDS} }", { itemID: ["ID!", "ark:/13030/#{itemID}"] }, true).dig("item")
  data or halt(404)
  return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" + formatItemData(data, params['expand'])
end

###################################################################################################
get %r{/dspace-rest/collections/([^/]+)/items} do |collection|
  verifyLoggedIn

  collection =~ /^(cdl_rw|iis_general|jtest|root)$/ or halt(404, "Invalid collection")

  offset = (params['offset'] || 0).to_i

  limit  = (params['limit'] || 10).to_i
  limit >= 1 && limit <= 100 or halt(401, "Limit out of range")

  if offset > 0
    moreToken = $nextMoreToken["#{collection}:#{offset}"]
    doQuery = !moreToken.nil?
  else
    moreToken = nil
    doQuery = true
  end

  if doQuery
    data = apiQuery("""
      unit(id: $collection) {
        items(first: $limit, include: [EMBARGOED,WITHDRAWN,EMPTY,PUBLISHED], more: $more) {
          more
          nodes {
            #{ITEM_FIELDS}
          }
        }
      }""",
      { collection: ["ID!", collection],
        limit: ["Int", limit],
        more: ["String", moreToken]
      }, true)
  else
    data = {}
  end

  $nextMoreToken.size >= MAX_NEXT_MORE_TOKEN and $nextMoreToken.shift
  $nextMoreToken["#{collection}:#{offset+limit}"] = data.dig("unit", "items", "more")

  formatted = (data.dig("unit", "items", "nodes") || []).map { |itemData|
    formatItemData(itemData, params['expand'])
  }

  content_type "text/xml"
  return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" +
         "<items>" +
         formatted.join("\n") +
         "</items>"
end

###################################################################################################
def errHalt(httpCode, message)
  puts "Error #{httpCode}: #{message}"
  halt httpCode, message
end

###################################################################################################
post "/dspace-swordv2/collection/13030/:collection" do |collection|

  # POST /dspace-swordv2/collection/13030/cdl_rw
  # with data <entry xmlns="http://www.w3.org/2005/Atom">
  #              <title>From Elements (0be0869c-6f32-48eb-b153-3f980b217b26)</title></entry>
  #              ...

  # Parse the body as XML, and locate the <entry>
  request.body.rewind
  body = Nokogiri::XML(request.body.read).remove_namespaces!
  entry = body.xpath("entry") or errHalt(400, "can't locate <entry> in request: #{body}")

  # Grab the Elements GUID for this publication
  title = (entry.xpath("title") or raise("can't locate <title> in entry: #{body}")).text
  guid = title[/\b\w{8}-\w{4}-\w{4}-\w{4}-\w{12}\b/] or errHalt(400, "can't find guid in title #{title.inspect}")

  # Omitting the "in-progress" header would imply that we should commit this item now, but we have
  # no metadata so that would not be reasonable.
  request.env['HTTP_IN_PROGRESS'] == 'true' or errHalt(400, "can't finalize item without any metadata")

  # Make an eschol ARK for this pub (if we've seen the pub before, the same old ark will be returned)
  ark = mintArk(guid)

  # Return a customized XML response.
  content_type "application/atom+xml; type=entry;charset=UTF-8"
  [201, xmlGen('''
    <entry xmlns="http://www.w3.org/2005/Atom">
      <content src="<%=$submitServer%>/swordv2/edit-media/<%=ark%>" type="application/zip"/>
      <link href="<%=$submitServer%>/swordv2/edit-media/<%=ark%>"rel="edit-media" type="application/zip"/>
      <title xmlns="http://purl.org/dc/terms/"><%=title%></title>
      <title type="text"><%=title%></title>
      <rights type="text"/>
      <updated><%=DateTime.now.iso8601%></updated>
      <generator uri="http://escholarship.org/ns/dspace-sword/1.0/" version="1.0">help@escholarship.org</generator>
      <id><%=$submitServer%>/swordv2/edit/<%=ark%></id>
      <link href="<%=$submitServer%>/swordv2/edit/<%=ark%>" rel="edit"/>
      <link href="<%=$submitServer%>/swordv2/edit/<%=ark%>"rel="http://purl.org/net/sword/terms/add"/>
      <link href="<%=$submitServer%>/swordv2/edit-media/<%=ark%>.atom" rel="edit-media"
            type="application/atom+xml; type=feed"/>
      <packaging xmlns="http://purl.org/net/sword/terms/">http://purl.org/net/sword/package/SimpleZip</packaging>
      <treatment xmlns="http://purl.org/net/sword/terms/">A metadata only item has been created</treatment>
    </entry>''', binding, xml_header: false)]
end

###################################################################################################
put "/dspace-rest/items/:itemGUID/metadata" do |itemID|
  # The ID should be an ARK, obtained earlier from the Sword post.
  itemID =~ /^qt\w{8}$/ or raise("itemID #{itemID.inspect} should be an eschol short ark")
  destroyOnFail(itemID) { # clean up after ourselves if anything goes wrong

    # PUT /rest/items/4463d757-868a-42e2-9aab-edc560089ca1/metadata
    # with data <metadataentries><metadataentry><key>dc.type</key><value>Article</value></metadataentry>
    #                            <metadataentry><key>dc.title</key><value>Targeting vivax malaria...
    #                            ...


    # Grab the body. It should be an XML set of metadata entries.
    request.body.rewind
    body = Nokogiri::XML(request.body.read, nil, "UTF-8", &:noblanks).remove_namespaces!
    puts "dspaceMetaPut: body=#{body.to_xml}"

    # We should now be able to figure out the Elements pub ID. Let's associate it with the ark that
    # we created in the earlier sword post.
    pubID = who = nil
    body.xpath(".//metadataentry").each { |ent|
      ent.text_at("key") == "elements-pub-id" and pubID = ent.text_at("value")
      ent.text_at("key") == "depositor-email" and who = ent.text_at("value")
    }
    pubID or raise("Can't find elements-pub-id in feed")
    who or raise("Can't find depositor-email in feed")

    puts "Found pubID=#{pubID.inspect}, who=#{who.inspect}."
    $recentArkInfo.size >= MAX_RECENT_ARK_INFO and $recentArkInfo.shift
    $recentArkInfo[itemID] = { pubID: pubID, who: who }

    # Make sure it hasn't already been deposited (would indicate that somehow Elements didn't
    # record the connection)
    if $arkDb.get_first_value("SELECT external_id FROM arks WHERE source='elements' AND external_id=?", pubID)
      userErrorHalt(itemID, "This publication was already deposited.")
    end

    # Now that we have a real pub ID, record it in the ark database.
    $arkDb.execute("UPDATE arks SET external_id=? WHERE source=? AND id=?",
      [pubID, 'elements', normalizeArk(itemID).sub("ark:/", "ark:")])

    # Update the metadata on disk
    checkForMetaUpdate(nil, "ark:/13030/#{itemID}", body, DateTime.now)

    # All done.
    content_type "text/plain"
    nil  # content length zero, and HTTP 200 OK
  }
end

###################################################################################################
post "/dspace-rest/items/:itemGUID/bitstreams" do |shortArk|
  shortArk =~ /^qt\w{8}$/ or raise("invalid ARK")

  destroyOnFail(shortArk) { # clean up after ourselves if anything goes wrong

    content_type "text/xml"

    fileName = params['name'] or raise("missing 'name' param")
    fileVersion = params['description']  # will be missing if user chose '[None]'

    request.body.rewind
    outFilename, size, mimeType = depositFile("ark:/13030/#{shortArk}", fileName, fileVersion, request.body)

    # POST /rest/items/4463d757-868a-42e2-9aab-edc560089ca1/bitstreams?name=anvlspec.pdf&description=Accepted%20version
    # TODO - customize raw response
    xmlGen('''
      <bitstream>
        <link>/rest/bitstreams/<%=shortArk%>/<%=CGI.escape(fileName)%></link>
        <expand>parent</expand>
        <expand>policies</expand>
        <expand>all</expand>
        <name><%=outFilename%></name>
        <type>bitstream</type>
        <UUID><%=shortArk%>/<%=CGI.escape(outFilename)%></UUID>
        <bundleName>ORIGINAL</bundleName>
        <description><%=fileVersion%></description>
        <mimeType><%=mimeType%></mimeType>
        <retrieveLink>/foo/bar</retrieveLink>
        <sequenceId>-1</sequenceId>
        <sizeBytes><%=size%></sizeBytes>
      </bitstream>''', binding)
  }
end

###################################################################################################
get %r{/dspace-rest/bitstreams/([^/]+)/(.*)/policy} do |itemID, path|
  content_type "application/atom+xml; type=entry;charset=UTF-8"
  itemData = apiQuery("item(id: $itemID) { status }", { itemID: ["ID!", "ark:/13030/#{itemID}"] }, true).dig("item")
  itemData or errHalt(404, "item #{itemID} not found")
  puts "itemData=#{itemData}"
  policyGroup = (itemData['status'] =~ /PUBLISHED|EMPTY/) ? 0 : 9
  [200, xmlGen('''
    <resourcePolicies>
      <resourcepolicy>
        <action>READ</action>
        <groupId><%= policyGroup %></groupId>
        <id><%= policyGroup+32 %></id>
        <resourceId><%= itemID+"/"+path %>/</resourceId>
        <resourceType>bitstream</resourceType>
        <rpType>TYPE_INHERITED</rpType>
      </resourcepolicy>
    </resourcePolicies>''', binding)]
end

###################################################################################################
delete "/dspace-rest/bitstreams/:itemID/:filename/policy/:policyID" do |itemID, filename, policyID|
  # After redepositing a file, Elements goes and deletes the policy from the new file.
  # Not sure what that's supposed to mean, but maybe it's a signal to go ahead and republish
  # the item.

  if isPublished(itemID) && isPending(itemID)
    info = $recentArkInfo[itemID]
    if info
      approveItem("ark:/13030/#{itemID}", info[:pubID], info[:who], false)
    else
      approveItem("ark:/13030/#{itemID}", arkToPubID(itemID), nil, false)
    end
  end

  # Return a fake response.
  [204, "Deleted."]
end

###################################################################################################
post "/dspace-swordv2/edit/:itemID" do |itemID|
  # POST /dspace-swordv2/edit/4463d757-868a-42e2-9aab-edc560089ca1

  itemID =~ /^qt\w{8}$/ or raise("itemID #{itemID.inspect} should be an eschol short ark")

  destroyOnFail(itemID) { # clean up after ourselves if anything goes wrong

    # The only reason to send this, we think, is to omit the In-Progress header, telling us to
    # publish the item.
    request.env['HTTP_IN_PROGRESS'] != 'true' or errHalt(400, "non-finalizing edit")

    request.body.rewind
    request.body.read.strip == "" or errHalt(400, "don't know what to do with actual edit data")

    # Time to publish this thing.
    info = $recentArkInfo[itemID]
    if info
      approveItem("ark:/13030/#{itemID}", info[:pubID], info[:who], false)
    else
      approveItem("ark:/13030/#{itemID}", arkToPubID(itemID), nil, false)
    end

    # Elements doesn't seem to care what we return, as long as it's XML. Hmm.
    content_type "application/atom+xml; type=entry;charset=UTF-8"
    [200, xmlGen('''<entry xmlns="http://www.w3.org/2005/Atom" />''', binding, xml_header: false)]
  }
end

###################################################################################################
get "/dspace-oai" do
  if params['verb'] == 'ListSets'
    content_type "text/xml"
    xmlGen('''
      <OAI-PMH xmlns="http://www.openarchives.org/OAI/2.0/"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
               xsi:schemaLocation="http://www.openarchives.org/OAI/2.0/
               http://www.openarchives.org/OAI/2.0/OAI-PMH.xsd">
        <responseDate>2002-08-11T07:21:33Z</responseDate>
        <request verb="ListSets">http://an.oa.org/OAI-script</request>
        <ListSets>
          <set>
            <setSpec>cdl_rw</setSpec>
            <setName>cdl_rw</setName>
          </set>
          <set>
            <setSpec>iis_general</setSpec>
            <setName>iis_general</setName>
          </set>
          <set>
            <setSpec>jtest</setSpec>
            <setName>jtest</setName>
          </set>
          <set>
            <setSpec>root</setSpec>
            <setName>root</setName>
          </set>
        </ListSets>
      </OAI-PMH>''', binding)
  else
    if params['verb'] == 'ListIdentifiers' && !params['resumptionToken']
      # For now, defeat differential harvest. Instead, just return identifiers in the 'jtest' set
      params.delete('from')
      params['set'] = 'jtest'
    end

    # Proxy the OAI query over to the eschol API server, and return its results
    response = HTTParty.get("#{$escholServer}/oai", query: params, headers: { 'Privileged' => $privApiKey })
    content_type response.headers['Content-Type']
    return [response.code, response.body]
  end
end

###################################################################################################
def arkToPubID(ark)
  pubID = $arkDb.get_first_value("SELECT external_id FROM arks WHERE source='elements' AND id=?",
                                 normalizeArk(ark))
  pubID && pubID =~ /^\d+$/ and return pubID
  return ($recentArkInfo[getShortArk(ark)] || {})[:pubID]
end

###################################################################################################
def userErrorHalt(ark, msg)
  puts "Recording user error #{msg.inspect} for ark #{ark.inspect}."

  # Find the pub corresponding to this ARK
  pubID = arkToPubID(ark)
  if pubID
    puts "Found pubID=#{pubID.inspect}"
    $userErrors.size >= MAX_USER_ERRORS and $userErrors.shift
    $userErrors[pubID] = { time: Time.now, msg: msg }
  else
    puts "Hmm, couldn't find a pub_id"
  end
  errHalt(400, msg)
end

###################################################################################################
get "/dspace-userErrorMsg/:pubID" do |pubID|
  # CORS support
  origin = request.env['HTTP_ORIGIN']
  origin =~ /oapolicy.universityofcalifornia.edu/ and headers 'Access-Control-Allow-Origin' => origin

  # See if we have a pending message associated with this pub ID
  entry = $userErrors.delete(pubID)
  entry and return entry[:msg]

  # Huh. Oh well, maybe it wasn't a user error but an internal error instead.
  errHalt(404, "Unknown pub")
end

###################################################################################################
get %r{/dspace-preview/(.*)} do |path|
  path =~ %r{^(qt\w{8})/(content/.*)} or halt(400)
  itemID, contentPath = $1, $2
  CGI.unescape(contentPath).include?('..') and halt(400)
  calcContentReadKey(itemID, contentPath) == params['key'] or halt(403)
  fullPath = arkToFile(itemID, CGI.unescape(contentPath))
  send_file(fullPath)
end
