# An OAI-PMH provider layer, wrapped around eScholarship's main GraphQL API

require 'oai'

def apiQuery(query, **args)
  args.empty? and query = "query { #{query} }"
  response = Schema.execute(query, variables: JSON.parse(args.to_json))
  response['errors'] and raise("GraphQL error: #{response['errors'][0]['message']}")
  response['data']
end

class EscholModel < OAI::Provider::Model
  def earliest
    apiQuery("items(first:1, order:UPDATED_ASC) { nodes { updated } }").dig("items", "nodes", 0, "updated")
  end

  def latest
    apiQuery("items(first:1, order:UPDATED_DESC) { nodes { updated } }").dig("items", "nodes", 0, "updated")
  end

  def sets
    nil
  end

  def find(selector, opts={})
    raise NotImplementedError.new
  end
end

class EscholProvider < OAI::Provider::Base
  repository_name 'eScholarship'
  repository_url 'https://escholarship.org/oai'
  record_prefix 'oai:escholarship.org'
  sample_id 'qt4590m805'
  admin_email 'help@escholarship.org'
  source_model EscholModel.new
end
