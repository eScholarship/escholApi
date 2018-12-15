#!/usr/bin/env ruby

# Hack-n-test script for the eschol API

# Use bundler to keep dependencies local
require 'rubygems'
require 'bundler/setup'

require 'httparty'

# Go to the right URLs for the front-end+api and submission systems
$hostname = `/bin/hostname`.strip
$escholServer, $submitServer = case $hostname
  when /pub-.*-stg/; ["http://pub-jschol-stg.escholarship.org", "https://pub-submit-stg.escholarship.org"]
  when /pub-.*-prd/; ["https://escholarship.org",               "https://submit.escholarship.org"]
  else raise("unrecognized host")
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
  response.code == 200 or raise("Internal error (graphql): HTTP code #{response.code}")
  response['errors'] and raise("Internal error (graphql): #{response['errors'][0]['message']}")
  response['data']
end

#################################################################################################
# Send a GraphQL query to the eschol API, returning the JSON results.
def apiMutation(mutation, vars)
  query = "mutation(#{vars.map{|name, pair| "$#{name}: #{pair[0]}"}.join(", ")}) { #{mutation} }"
  varHash = Hash[vars.map{|name,pair| [name.to_s, pair[1]]}]
  headers = { 'Content-Type' => 'application/json' }
  headers['Privileged'] = ENV['ESCHOL_PRIV_API_KEY'] or raise("missing env ESCHOL_PRIV_API_KEY")
  response = HTTParty.post("#{$escholServer}/graphql",
               :headers => headers,
               :body => { variables: varHash, query: query }.to_json)
  response.code == 200 or raise("Internal error (graphql): HTTP code #{response.code}")
  response['errors'] and raise("Internal error (graphql): #{response['errors'][0]['message']}")
  response['data']
end

#################################################################################################
#result = apiQuery("item(id: $itemID) { title }", { itemID: ["ID!", "ark:/13030/qt99m5j3q7"] })
result = apiMutation("mintProvisionalID(input: $input) { id }", { input: ["MintProvisionalIDInput!",
  { sourceName: "elements", sourceID: "abc123" }
] })
puts "result=#{result}"