# An OAI-PMH provider layer, wrapped around eScholarship's main GraphQL API

require 'date'
require 'time'

require 'oai'

###################################################################################################
# Send a GraphQL query to the main API, returning the JSON results
def apiQuery(query, **args)
  args.empty? and query = "query { #{query} }"
  response = Schema.execute(query, variables: JSON.parse(args.to_json))
  response['errors'] and raise("Internal error (graphql): #{response['errors'][0]['message']}")
  response['data']
end

###################################################################################################
class OclcDublinCore < OAI::Provider::Metadata::Format
  def initialize
    @prefix = 'oclc_dc'
    @schema = 'http://www.escholarship.org/schema/oclc_dc.xsd'
    @namespace = 'http://xtf.cdlib.org/oclc_dc'
    @element_namespace = 'dc'
  end
end

###################################################################################################
# We use a special resumption token class, since most of the actual work of resumption encode/
# decode is done within the GraphQL API.
class EscholResumptionToken
  attr_reader :opts, :total, :more

  def initialize(opts, total, more)
    @opts = opts
    @total = total
    @more = more
  end

  # Encode the resumption token to pass to the client
  def to_xml
    xml = Builder::XmlMarkup.new
    attrs = (@total ? { completeListSize: @total } : {})
    xml.resumptionToken "#{@opts[:metadata_prefix]}:#{@more}", **attrs
    xml.target!
  end

  # Decode a resumption token into the prefix and opaque 'more' string for the GraphQL API
  def self.decode(str)
    str =~ /^([\w_]+):([\w\d]+)$/ or raise(OAI::ArgumentException.new)
    new({ metadata_prefix: $1 }, nil, $2)
  end
end

###################################################################################################
# Wrap the JSON 'item' output from the GraphQL API as an OAI record
class EscholRecord
  def initialize(data)
    @data = data
  end

  def id
    @data['id'].sub(%r{ark:/}, '')  # ark:/ prefix is automatically added by outer OAI library
  end

  def updated_at
    Time.parse(@data['updated'])
  end

  def dcFields(xml)
    xml.tag!("dc:identifier", @data['id'].sub(%r{^ark:/13030/}, ''))
    @data['title'] and xml.tag!("dc:title", @data['title'].gsub(/<\/?[^>]*>/, ""))  # strip HTML tags
    (@data.dig('authors', 'nodes')||[]).each { |auth| xml.tag!("dc:creator", auth['name']) }
    (@data.dig('contributors', 'nodes')||[]).each { |contrib| xml.tag!("dc:contributor", contrib['name']) }
    xml.tag!("dc:date", @data['published'])
    @data['abstract'] and xml.tag!("dc:description", @data['abstract'].gsub(/<\/?[^>]*>/, ""))  # strip HTML tags
    (@data['subjects']||[]).each { |subj| xml.tag!("dc:subject", subj) }
    @data['language'] and xml.tag!("dc:language", @data['language'])
    @data['contentType'] and xml.tag!("dc:format", @data['contentType'])
    xml.tag!("dc:rights", @data['rights'] || 'public')
    xml.tag!("dc:publisher", "eScholarship, University of California")
  end

  def to_oai_dc
    xml = Builder::XmlMarkup.new
    header_spec = {
      'xmlns:oai_dc' => "http://www.openarchives.org/OAI/2.0/oai_dc/",
      'xmlns:dc' => "http://purl.org/dc/elements/1.1/",
      'xmlns:xsi' => "http://www.w3.org/2001/XMLSchema-instance",
      'xsi:schemaLocation' =>
        %{http://www.openarchives.org/OAI/2.0/oai_dc/
          http://www.openarchives.org/OAI/2.0/oai_dc.xsd}.gsub(/\s+/, ' ')
    }
    xml.tag!("oai_dc:dc", header_spec) {
      dcFields(xml)
      xml.tag!("dc:type", @data['type'].downcase)
      if @data['journal']
        issData = [@data['journal']]
        @data['volume'] and issData << "vol #{@data['volume']}"
        @data['issue'] and issData << "iss #{@data['issue']}"
        xml.tag!("dc:source", issData.compact.join(", "))
        @data['fpage'] and xml.tag!("dc:coverage", [@data['fpage'], @data['lpage']].compact.join(" - "))
      elsif @data['publisher']
        xml.tag!("dc:source", @data['publisher'])
      end
    }
    xml.target!
  end

  def to_oclc_dc
    xml = Builder::XmlMarkup.new
    header_spec = {
      'xmlns:oclc_dc' => "http://xtf.cdlib.org/oclc_dc",  # yes, different than OAI
      'xmlns:dc' => "http://purl.org/dc/elements/1.1/",
      'xmlns:xsi' => "http://www.w3.org/2001/XMLSchema-instance",
      'xsi:schemaLocation' =>
        %{http://xtf.cdlib.org/oclc_dc
          http://www.escholarship.org/schema/oclc_dc.xsd}.gsub(/\s+/, ' ')
    }
    xml.tag!("oclc_dc:dc", header_spec) {
      dcFields(xml)

      # Special type logic for OCLC
      xml.tag!("dc:type", (@data['type'] == "ARTICLE" && @data['journal'] && (@data['volume'] || @data['issue'])) ? "article" :
                          (@data['type'] == "MONOGRAPH") ? "monograph" :
                          "publication")

      # OCLC-specific way to encode journal-related fields
      if @data['journal']
        xml.tag!("dc:source", @data['journal'])
        issData = []
        @data['volume'] and issData << "vol #{@data['volume']}"
        @data['issue'] and issData << "iss #{@data['issue']}"
        @data['fpage'] and issData << [@data['fpage'], @data['lpage']].compact.join("-")
        xml.tag!("dc:source", issData.join(", "))
        xml.tag!("dc:source", @data['issn'])
      end

      # Second version of identifier for OCLC harvesting
      xml.tag!("dc:identifier", "https://escholarship.org/uc/item/#{@data['id'].sub(%r{^ark:/13030/qt}, '')}")
    }
    xml.target!
  end
end

###################################################################################################
# An OAI model for eScholarship's API
class EscholModel < OAI::Provider::Model
  # Earliest update: date of first item in ascending update order
  def earliest
    apiQuery("items(first:1, order:UPDATED_ASC) { nodes { updated } }").dig("items", "nodes", 0, "updated")
  end

  # Latest update: first item in *descending* update order
  def latest
    apiQuery("items(first:1, order:UPDATED_DESC) { nodes { updated } }").dig("items", "nodes", 0, "updated")
  end

  # TODO
  def sets
    nil
  end

  # The main query method
  def find(selector, opts={})
    puts "find: selector=#{selector} opts=#{opts}"

    itemFields = %{
      id
      updated
      title
      published
      abstract
      authors { nodes { name } }
      contributors { nodes { name } }
      subjects
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

    if selector != :all
      selector.sub!("ark:/13030/", "")
      selector =~ /^qt\w{8}$/ or raise(OAI::IdException.new)
      record = apiQuery(%{
        item(id: "#{selector}") { #{itemFields} }
      }).dig("item")
      return EscholRecord.new(record)
    end

    # If there's a resumption token, decode it, and grab the metadata prefix
    resump = nil
    if opts[:resumption_token]
      resump = EscholResumptionToken.decode(opts[:resumption_token])
      opts[:metadata_prefix] = resump.opts[:metadata_prefix]
    end

    # Now form a GraphQL query to capture the data we want
    data = apiQuery(%{
      items(
        order: UPDATED_DESC
        #{resump ? ", more: \"#{resump.more}\"" : ''}
      ) {
        #{resump ? '' : 'total'}
        more
        nodes { #{itemFields} }
      }
    }).dig("items")

    # Map the results to OAI records
    records = data['nodes'].map { |record|
      EscholRecord.new(record)
    }

    # And add a resumption token if there are more records.
    if data['more']
      OAI::Provider::PartialResult.new(records, EscholResumptionToken.new(opts, data['total'], data['more']))
    else
      records
    end
  end
end

###################################################################################################
class EscholProvider < OAI::Provider::Base
  repository_name 'eScholarship'
  repository_url 'https://escholarship.org/oai'
  record_prefix 'ark:'
  sample_id 'qt4590m805'
  admin_email 'help@escholarship.org'
  source_model EscholModel.new
  register_format OclcDublinCore.instance
end
