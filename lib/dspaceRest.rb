# A DSpace wrapper around escholarship, used to integrate eschol content into Symplectic Elements

require 'date'
require 'digest'
require 'json'
require 'pp'
require 'securerandom'
require 'time'
require 'xmlsimple'

###################################################################################################
# Use the right paths to everything
$arkDataDir = "/apps/eschol/erep/data"
$controlDir = "/apps/eschol/erep/xtf/control"

credFile = "#{ENV['HOME']}/.passwords/rt2_adapter_creds.json"
$creds = File.exist?(credFile) ? JSON.parse(File.read(credFile)) : {}

$sessions = {}
MAX_SESSIONS = 5

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
def dspaceStatus
  content_type "text/xml"
  if $sessions[getSession][:loggedIn]
    xmlGen('''
      <status>
        <authenticated>true</authenticated>
        <email><%=email%></email>
        <fullname>DSpace user</fullname>
        <okay>true</okay>
      </status>''', {email: $creds['email']})
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
def dspaceLogin
  content_type "text/plain;charset=utf-8"
  params['email'] == $creds['email'] && params['password'] == $creds['password'] or halt(401, "Unauthorized.\n")
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
def dspaceCollections
  verifyLoggedIn
  content_type "text/xml"
  inner = %w{cdl_rw iis_general root}.map { |unitID|
    data = apiQuery("unit(id: $unitID) { items { total } }", { unitID: ["ID!", unitID] }).dig("unit")
    unitID.sub!("root", "jtest")
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
def dspaceItems
  verifyLoggedIn
  request.path =~ /(qt\w{8})/ or halt(404, "Invalid item ID")
  itemID = $1
  itemFields = %{
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
    }
    units {
      id
      name
      parents {
        name
      }
    }
    abstract
    added
    bookTitle
    contentLink
    contentType
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
  }
  data = apiQuery("item(id: $itemID) { #{itemFields} }", { itemID: ["ID!", "ark:/13030/#{itemID}"] }, true).dig("item")
  data.delete_if{ |k,v| v.nil? || v.empty? }

  metaXML = stripHTML(XmlSimple.xml_out(data, {suppress_empty: nil, noattr: true, rootname: "metadata"}))
  lastMod = Time.parse(data.dig("updated")).strftime("%Y-%m-%d %H:%M:%S")

  collections = (data['units'] || []).map { |unit|
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
        <name><%= unit.dig("parents", 0, "name") + ": " + unit["name"] %></name>
        <type>collection</type>
        <UUID><%= unit["id"] %></UUID>
        <copyrightText/>
        <introductoryText/>
        <numberItems><%= unit.dig("items", "total") %></numberItems>
        <shortDescription><%= unit["id"] %></shortDescription>
        <sidebarText/>
      </parentCollection>''', binding, xml_header: false)
  }.join("\n")

  bitstreams = ""
  if data['contentLink'] && data['contentType'] == "application/pdf"
    bitstreams = xmlGen('''
      <bitstreams>
        <link><%= data["contentLink"] %></link>
        <expand>parent</expand>
        <expand>policies</expand>
        <expand>all</expand>
        <name><%= File.basename(data["contentLink"]) %></name>
        <type>bitstream</type>
        <UUID><%= data["contentLink"] %></UUID>
        <bundleName>ORIGINAL</bundleName>
        <description>Accepted version</description>
        <format>Adobe PDF</format>
        <mimeType>application/pdf</mimeType>
        <link><%= data["contentLink"] %></link>
        <sequenceId>-1</sequenceId>
        <sizeBytes>61052</sizeBytes>
      </bitstreams>''', binding, xml_header: false)
  end

  content_type "text/xml"
  xmlGen('''
    <item>
      <link>/rest/items/13030/<%= itemID %></link>
      <expand>parentCommunityList</expand>
      <expand>all</expand>
      <handle>13030/<%= itemID %></handle>
      <name><%= data["title"] %></name>
      <type>item</type>
      <%== metaXML %>
      <UUID><%= itemID %></UUID>
      <archived>true</archived>
      <lastModified><%= lastMod %></lastModified>
      <%== collections %>
      <%== collections.gsub("parentCollection", "parentCollectionList") %>
      <withdrawn><%= data.dig("status") == "WITHDRAWN" %></withdrawn>
      <%== bitstreams %>
    </item>''', binding)
end

###################################################################################################
# Convert an elements publication GUID to an ARK on our system. This will create
# a new ark if we haven't seen the publication before.
def mintArk(pubGuid)
  ark = `#{$controlDir}/tools/mintArk.py elements #{pubGuid}`.strip()
  return (ark =~ %r<^ark:/?13030/\w{10}$>) ? ark : raise("bad result '#{ark}' from mintArk")
end

###################################################################################################
def dspaceSwordPost
  request.path =~ %r{collection/13030} or raise   # we only actually support the one sword API

  # Parse the body as XML, and locate the <entry>
  request.body.rewind
  body = Nokogiri::XML(request.body.read)
  body.remove_namespaces!
  entry = body.xpath("entry")
  entry or raise("can't locate <entry> in request: #{body}")

  # Grab the Elements GUID for this publication
  title = entry.xpath("title")
  title or raise("can't locate <title> in entry: #{body}")
  title = title.text
  guid = title[/\b\w{8}-\w{4}-\w{4}-\w{4}-\w{12}\b/] or raise("can't find guid in title #{title.inspect}")

  # Make an eschol ARK for this pub
  #ark = mintArk(guid)
  #puts "ark=#{ark}"

  # POST /dspace-swordv2/collection/13030/cdl_rw
  # with data <entry xmlns="http://www.w3.org/2005/Atom">
  #              <title>From Elements (0be0869c-6f32-48eb-b153-3f980b217b26)</title></entry>
  # TODO - customize raw response
  content_type "application/atom+xml; type=entry;charset=UTF-8"
  [201, xmlGen('''
    <entry xmlns="http://www.w3.org/2005/Atom">
      <content src="https://pub-submit-stg.escholarship.org/swordv2/edit-media/a2c851b6-b734-4764-a34c-1b785a6cdc7c"
               type="application/zip"/>
      <link href="https://pub-submit-stg.escholarship.org/swordv2/edit-media/a2c851b6-b734-4764-a34c-1b785a6cdc7c"
            rel="edit-media" type="application/zip"/>
      <title xmlns="http://purl.org/dc/terms/"><%= title %></title>
      <title type="text"><%= title %></title>
      <rights type="text"/>
      <updated>2018-07-06T07:00:00.000Z</updated>
      <generator uri="http://escholarship.org/ns/dspace-sword/1.0/" version="1.0">help@escholarship.org</generator>
      <id>https://pub-submit-stg.escholarship.org/swordv2/edit/a2c851b6-b734-4764-a34c-1b785a6cdc7c</id>
      <link href="https://pub-submit-stg.escholarship.org/swordv2/edit/a2c851b6-b734-4764-a34c-1b785a6cdc7c" rel="edit"/>
      <link href="https://pub-submit-stg.escholarship.org/swordv2/edit/a2c851b6-b734-4764-a34c-1b785a6cdc7c"
            rel="http://purl.org/net/sword/terms/add"/>
      <link href="https://pub-submit-stg.escholarship.org/swordv2/edit-media/a2c851b6-b734-4764-a34c-1b785a6cdc7c.atom"
            rel="edit-media" type="application/atom+xml; type=feed"/>
      <packaging xmlns="http://purl.org/net/sword/terms/">http://purl.org/net/sword/package/SimpleZip</packaging>
      <link href="https://pub-submit-stg.escholarship.org/swordv2/statement/a2c851b6-b734-4764-a34c-1b785a6cdc7c.rdf"
            rel="http://purl.org/net/sword/terms/statement" type="application/rdf+xml"/>
      <link href="https://pub-submit-stg.escholarship.org/swordv2/statement/a2c851b6-b734-4764-a34c-1b785a6cdc7c.atom"
            rel="http://purl.org/net/sword/terms/statement" type="application/atom+xml; type=feed"/>
      <treatment xmlns="http://purl.org/net/sword/terms/">A metadata only item has been created</treatment>
      <link href="https://pub-submit-stg.escholarship.org/jspui/view-workspaceitem?submit_view=Yes&amp;workspace_id=10"
            rel="alternate"/>
    </entry>''', binding, xml_header: false)]
end

###################################################################################################
def dspaceMetaPut
  request.body.rewind
  puts "dspaceMetaPut: body=#{request.body.read}"
  # PUT /rest/items/4463d757-868a-42e2-9aab-edc560089ca1/metadata
  # with data <metadataentries><metadataentry><key>dc.type</key><value>Article</value></metadataentry>
  #                            <metadataentry><key>dc.title</key><value>Targeting vivax malaria...
  content_type "text/plain"
  nil  # content length zero, and HTTP 200 OK
end

###################################################################################################
def dspaceBitstreamPost
  content_type "text/xml"
  # POST /rest/items/4463d757-868a-42e2-9aab-edc560089ca1/bitstreams?name=anvlspec.pdf&description=Accepted%20version
  # TODO - customize raw response
  xmlGen('''
    <bitstream>
      <link>/rest/bitstreams/a2c851b6-b734-4764-a34c-1b785a6cdc7c</link>
      <expand>parent</expand>
      <expand>policies</expand>
      <expand>all</expand>
      <name>anvlspec.pdf</name>
      <type>bitstream</type>
      <UUID>f4ae2285-f316-48df-b03b-1289a81d3252</UUID>
      <bundleName>ORIGINAL</bundleName>
      <checkSum checkSumAlgorithm="MD5">94ceff2e200b162a22f3abc32bae106f</checkSum>
      <description>Accepted version</description>
      <format>Adobe PDF</format>
      <mimeType>application/pdf</mimeType>
      <retrieveLink>/rest/bitstreams/a2c851b6-b734-4764-a34c-1b785a6cdc7c/retrieve</retrieveLink>
      <sequenceId>-1</sequenceId>
      <sizeBytes>61052</sizeBytes>
    </bitstream>''', binding)
end

###################################################################################################
def dspaceEdit
  # POST /dspace-swordv2/edit/4463d757-868a-42e2-9aab-edc560089ca1
  # Not sure what we receive here, nor what we should reply. Original log was incomplete
  # because Sword rejected the URL due to misconfiguration.
end

###################################################################################################
def dspaceOAI
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
        </ListSets>
      </OAI-PMH>''', binding)
  else
    if params['set'] == 'jtest'
      params['verb'] == 'ListIdentifiers' and params['from'] = "2018-05-04T10:20:57Z"
      params['set'] = "everything"
    else
      params['verb'] == 'ListIdentifiers' and params.delete('from') # Disable differential harvest for now
    end
    serveOAI
  end
end

###################################################################################################
def serveDSpace(op)
  puts "serveDSpace: op=#{op} path=#{request.path} params=#{params}"
  case "#{op} #{request.path}"
    when %r{GET /dspace-rest/status};          dspaceStatus
    when %r{GET /dspace-rest/(items|handle)/}; dspaceItems
    when %r{GET /dspace-rest/collections};     dspaceCollections
    when %r{POST /dspace-rest/login};          dspaceLogin
    when %r{GET /dspace-oai};                  dspaceOAI
    when %r{POST /dspace-swordv2};             dspaceSwordPost
    when %r{PUT /dspace-rest/items};           dspaceMetaPut
    when %r{POST /dspace-rest/items};          dspaceBitstreamPost
    else halt(404, "Not found.\n")
  end
end