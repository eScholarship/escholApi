
# Make it clear where the new session starts in the log file.
STDOUT.write "\n=====================================================================================\n"

class SinatraGraphql < Sinatra::Base
  set public_folder: 'public', static: true

  get '/' do
    token = ""
    erb :layout, locals: {token: token}
  end

  get '/chk' do
    "ok"
  end

  post '/graphql' do
    params =  JSON.parse(request.body.read)
    puts "query=#{params['query'].inspect}"
    result = Schema.execute(
      params['query'],
      variables: params['variables']
    )
    content_type :json
    result.to_json
  end

  get '/oai' do
    Thread.current[:graphqlApi] = "http://#{request.host}:3000/graphql"
    content_type 'text/xml'
    provider = EscholProvider.new
    provider.process_request(params)
  end

end
