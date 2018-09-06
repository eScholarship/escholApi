require 'erubis'
require 'nokogiri'

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

