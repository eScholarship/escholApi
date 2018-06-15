# A DSpace wrapper around escholarship, used to integrate eschol content into Symplectic Elements

require 'date'
require 'digest'
require 'json'
require 'pp'
require 'erubis'
require 'nokogiri'

$creds = JSON.parse(File.read("#{ENV['HOME']}/.passwords/rt2_adapter_creds.json"))

# Nice way to generate XML, just using ERB-like templates instead of Builder's weird syntax.
class XMLGen < Erubis::Eruby
  include Erubis::EscapeEnhancer
  def result(bnding, xml_header: true)
    doc = Nokogiri::XML(super(bnding), nil, "UTF-8", &:noblanks)
    return xml_header ? doc.to_xml : doc.root.to_xml
  end
end

###################################################################################################
def calcSessionID
  return Digest::SHA256.hexdigest(Date.today.to_s + $creds['email'] + $creds['password'])[0..31].upcase
end

###################################################################################################
def dspaceStatus
  if request.env['HTTP_COOKIE'] =~ /JSESSIONID=#{calcSessionID}/
    $statusLoggedIn ||= XMLGen.new '''
      <status>
        <authenticated>true</authenticated>
        <email><%=email%></email>
        <fullname>DSpace user</fullname>
        <okay>true</okay>
      </status>'''
      return $statusLoggedIn.result({email: $creds['email']}, xml_header: true)
  else
    $statusNotLoggedIn ||= XMLGen.new '''
      <status>
        <apiVersion>6</apiVersion>
        <authenticated>false</authenticated>
        <okay>true</okay>
        <sourceVersion>6.0</sourceVersion>
      </status>'''
    return $statusNotLoggedIn.result({}, xml_header: true)
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
def serveDSpace(op)
  case "#{op} #{request.path}"
    when "GET /dspace-rest/status"; dspaceStatus
    when "POST /dspace-rest/login"; dspaceLogin
    else halt(404, "Not found.\n")
  end
end