
require_relative './appBase'

###################################################################################################
class EscholAPI < AppBase

  def initialize
    super
    @schema = EscholSchema
  end

  #################################################################################################
  # Send a GraphQL query to the main API, returning the JSON results. Used by various wrappers
  # below (e.g. OAI and DSpace)
  def apiQuery(query, vars = {})
    if vars.empty?
      query = "query { #{query} }"
    else
      query = "query(#{vars.map{|name, pair| "$#{name}: #{pair[0]}"}.join(", ")}) { #{query} }"
    end
    varHash = Hash[vars.map{|name,pair| [name.to_s, pair[1]]}]
    response = Schema.execute(query, variables: varHash)
    response['errors'] and raise("Internal error (graphql): #{response['errors'][0]['message']}")
    response['data']
  end

  #################################################################################################
  # Note: GraphQL stuff is handled in AppBase
  #################################################################################################

  #################################################################################################
  def serveOAI
    content_type 'text/xml;charset=utf-8'
    provider = EscholProvider.new
    provider.process_request(params)
  end

  # OAI providers are required to support both GET and POST
  get '/oai' do
    serveOAI
  end
  post '/oai' do
    serveOAI
  end

  #################################################################################################
  # RSS feeds
  get "/rss/unit/:unitID" do |unitID|
    serveUnitRSS(unitID)
  end
end
