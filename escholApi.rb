require 'rack/protection'

# Make it clear where the new session starts in the log file.
STDOUT.write "\n=====================================================================================\n"

class SinatraGraphql < Sinatra::Base
  set public_folder: 'public', static: true

  get '/' do
    token = ""
    erb :graphiql, locals: {token: token}
  end

  post '/graphql' do
    params =  JSON.parse(request.body.read)
    result = Schema.execute(
      params['query'],
      variables: params['variables'] ? JSON.parse(params['variables']) : nil
    )
    content_type :json
    result.to_json
  end
end
