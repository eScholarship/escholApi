
# Make it clear where the new session starts in the log file.
STDOUT.write "\n=====================================================================================\n"

class SinatraGraphql < Sinatra::Base
  set public_folder: 'public', static: true

   # Compress things that can benefit
  use Rack::Deflater,
    :if => lambda { |env, status, headers, body|
      # advice from https://www.itworld.com/article/2693941/cloud-computing/why-it-doesn-t-make-sense-to-gzip-all-content-from-your-web-server.html
      return headers["Content-Length"].to_i > 1400
    }

  get '/graphql/iql' do
    token = ""
    erb :layout, locals: {token: token}
  end

  get %r{/graphql/iql/(.*)} do
    call env.merge("PATH_INFO" => "/#{params['captures'][0]}")
  end

  get '/chk' do
    "ok"
  end

  get '/graphql' do
    params['query'] or redirect(to('/graphql/iql'))
    content_type :json
    Schema.execute(params['query'], params['variables']).to_json
  end

  post '/graphql' do
    params =  JSON.parse(request.body.read)
    content_type :json
    Schema.execute(params['query'], params['variables']).to_json
  end

  def serveOAI
    Thread.current[:graphqlApi] = "http://#{request.host}:3000/graphql"
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

end
