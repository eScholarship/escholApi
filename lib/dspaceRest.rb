# A DSpace wrapper around escholarship, used to integrate eschol content into Symplectic Elements

require 'date'
require 'digest'
require 'json'
require 'pp'
require 'erubis'
require 'nokogiri'
require 'time'
require 'xmlsimple'

$creds = JSON.parse(File.read("#{ENV['HOME']}/.passwords/rt2_adapter_creds.json"))

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

###################################################################################################
def calcSessionID
  return Digest::SHA256.hexdigest(Date.today.to_s + $creds['email'] + $creds['password'])[0..31].upcase
end

###################################################################################################
def dspaceStatus
  content_type "text/xml"
  if request.env['HTTP_COOKIE'] =~ /JSESSIONID=#{calcSessionID}/
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
        <apiVersion>6</apiVersion>
        <authenticated>false</authenticated>
        <okay>true</okay>
        <sourceVersion>6.0</sourceVersion>
      </status>''', {})
  end
end

###################################################################################################
def dspaceLogin
  content_type "text/plain;charset=utf-8"
  params['email'] == $creds['email'] && params['password'] == $creds['password'] or halt(401, "Unauthorized.\n")
  headers 'Set-Cookie' => "JSESSIONID=#{calcSessionID}; "# +
                          "Expires=#{((Date.today + 1).to_time - Time.now).to_i}; " +
                          "Path=/; " +
                          "Secure; " +
                          "SameSite=Strict"
  "OK\n"
end

###################################################################################################
def verifyLoggedIn
  request.env['HTTP_COOKIE'] =~ /JSESSIONID=#{calcSessionID}/ or halt(401, "Unauthorized.\n")
end

###################################################################################################
def dspaceCollections
  verifyLoggedIn
  content_type "text/xml"
  xmlGen('''
    <collections>
      <collection>
        <link>/rest/collections/dec8a5dc-9f59-4eb0-885b-14d9e8963498</link>
        <expand>parentCommunityList</expand>
        <expand>parentCommunity</expand>
        <expand>items</expand>
        <expand>license</expand>
        <expand>logo</expand>
        <expand>all</expand>
        <handle>123456789/2</handle>
        <name>Test Collection</name>
        <type>collection</type>
        <UUID>dec8a5dc-9f59-4eb0-885b-14d9e8963498</UUID>
        <copyrightText/>
        <introductoryText/>
        <numberItems>3</numberItems>
        <shortDescription>Test</shortDescription>
        <sidebarText/>
      </collection>
    </collections>''', {})
end

###################################################################################################
def stripHTML(encoded)
  encoded.gsub("&amp;lt;", "&lt;").gsub("&amp;gt;", "&gt;").gsub(%r{&lt;/?\w+?&gt;}, "")
end

###################################################################################################
def dspaceItems
  verifyLoggedIn
  request.path =~ /(qt\w{8})/ or halt(400, "Invalid item ID")
  itemID = $1
  itemFields = %{
    id
    status
    updated
    title
    published
    abstract
    authors { nodes { name } }
    contributors { nodes { role name } }
    units { id items { total } }
    subjects
    keywords
    language
    type
    contentType
    rights
    journal
    volume
    issue
    fpage
    lpage
    issn
  }
  data = apiQuery("item(id: $itemID) { #{itemFields} }", { itemID: ["ID!", "ark:/13030/#{itemID}"] }).dig("item")
  data.delete_if{ |k,v| v.nil? || v.empty? }
  if data['fpage'] || data['lpage']
    data['pagination'] = "#{data['fpage']}-#{data['lpage']}"
  end

  metaXML = stripHTML(XmlSimple.xml_out(data, {suppress_empty: nil, noattr: true, rootname: "metadata"}))
  lastMod = Time.parse(data.dig("updated")).strftime("%Y-%m-%d %H:%M:%S")

  collections = (data['units'] || []).map { |unit|
    xmlGen('''
      <parentCollection>
        <link>/rest/collections/eschol/<%= unit["id"] %></link>
        <expand>parentCommunityList</expand>
        <expand>parentCommunity</expand>
        <expand>items</expand>
        <expand>license</expand>
        <expand>logo</expand>
        <expand>all</expand>
        <handle>eschol/<%= unit["id"] %></handle>
        <name><%= unit["id"] %></name>
        <type>collection</type>
        <UUID><%= unit["id"] %></UUID>
        <copyrightText/>
        <introductoryText/>
        <numberItems><%= unit.dig("items", "total") %></numberItems>
        <shortDescription><%= unit["id"] %></shortDescription>
        <sidebarText/>
      </parentCollection>''', binding, xml_header: false)
  }.join("\n")

  content_type "text/xml"
  xmlGen('''
    <item>
      <link>/rest/items/eschol/<%= itemID %></link>
      <expand>parentCollection</expand>
      <expand>parentCollectionList</expand>
      <expand>parentCommunityList</expand>
      <expand>bitstreams</expand>
      <expand>all</expand>
      <handle>eschol/<%= itemID %></handle>
      <name><%= data["title"] %></name>
      <type>item</type>
      <%== metaXML %>
      <UUID><%= itemID %></UUID>
      <archived>true</archived>
      <lastModified><%= lastMod %></lastModified>
      <%== collections %>
      <%== collections.gsub("parentCollection", "parentCollectionList") %>
      <withdrawn><%= data.dig("status") == "WITHDRAWN" %></withdrawn>
    </item>''', binding)
end

###################################################################################################
def serveDSpace(op)
  puts "serveDSpace: op=#{op} path=#{request.path} query=#{request.query_string} params=#{params}"
  case "#{op} #{request.path}"
    when %r{GET /dspace-rest/status};          dspaceStatus
    when %r{GET /dspace-rest/(items|handle)/}; dspaceItems
    when %r{GET /dspace-rest/collections};     dspaceCollections
    when %r{POST /dspace-rest/login};          dspaceLogin
    else halt(404, "Not found.\n")
  end
end