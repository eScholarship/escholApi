
# Make it clear where the new session starts in the log file.
STDOUT.write "\n=====================================================================================\n"

###################################################################################################
# Make puts thread-safe, and flush after every puts.
$stdoutMutex = Mutex.new
$workerNum = 0
$workerPrefix = ""
$nextThreadNum = 0
def puts(str)
  $stdoutMutex.synchronize {
    if !Thread.current[:number]
      allNums = Set.new
      Thread.list.each { |t| allNums << t[:number] }
      num = 0
      while allNums.include?(num)
        num += 1
      end
      Thread.current[:number] = num
    end
    STDOUT.puts "[#{$workerPrefix}#{Thread.current[:number]}] #{str}"
    STDOUT.flush
  }
end

###################################################################################################
class StdoutLogger
  def << (str)
    puts(str)
  end
end

$stdoutLogger = StdoutLogger.new

# Replace Rack's CommonLogger with a slight modification to log Referer and X-Amzn-Trace-Id
class AccessLogger

  FORMAT = %{%s - %s [%s] "%s %s%s %s" %d %s %0.4f %s %s\n}

  def initialize(app, logger=nil)
    @app = app
    @logger = logger
  end

  def call(env)
    began_at = Rack::Utils.clock_time
    status, header, body = @app.call(env)
    header = Rack::Utils::HeaderHash.new(header)
    body = Rack::BodyProxy.new(body) { log(env, status, header, began_at) }
    [status, header, body]
  end

  private

  def log(env, status, header, began_at)
    length = extract_content_length(header)

    msg = FORMAT % [
      env['HTTP_X_FORWARDED_FOR'] || env["REMOTE_ADDR"] || "-",
      env["REMOTE_USER"] || "-",
      Time.now.strftime("%d/%b/%Y:%H:%M:%S %z"),
      env[Rack::REQUEST_METHOD],
      env[Rack::PATH_INFO],
      env[Rack::QUERY_STRING].empty? ? "" : "?#{env[Rack::QUERY_STRING]}",
      env[Rack::HTTP_VERSION],
      status.to_s[0..3],
      length,
      Rack::Utils.clock_time - began_at,
      extract_referer(env, header),  # added
      extract_trace(env, header) ]   # added

    logger = @logger || env[Rack::RACK_ERRORS]
    # Standard library logger doesn't support write but it supports << which actually
    # calls to write on the log device without formatting
    if logger.respond_to?(:write)
      logger.write(msg)
    else
      logger << msg
    end
  end

  def extract_content_length(headers)
    value = headers[Rack::CONTENT_LENGTH] or return '-'
    value.to_s == '0' ? '-' : value
  end

  def extract_referer(env, headers)
    value = env['HTTP_REFERER'] || headers['REFERER'] or return '-'
    return quote(value)
  end

  def extract_trace(env, headers)
    value = env['HTTP_X_AMZN_TRACE_ID'] || headers['X-AMZN-TRACE-ID'] or return '-'
    return quote(value)
  end

  def quote(value)
    return "\"#{value.gsub("\"", "%22").gsub(/\s/, "+")}\""
  end
end

###################################################################################################
class SinatraGraphql < Sinatra::Base
  set public_folder: 'public', static: true
  set :show_exceptions, false
  # Replace Sinatra's normal logging with one that goes to our overridden stdout puts, so we
  # can include the pid and thread number with each request.
  set :logging, false
  use AccessLogger, $stdoutLogger

   # Compress things that can benefit
  use Rack::Deflater,
    :if => lambda { |env, status, headers, body|
      # advice from https://www.itworld.com/article/2693941/cloud-computing/why-it-doesn-t-make-sense-to-gzip-all-content-from-your-web-server.html
      return headers["Content-Length"].to_i > 1400
    }

  #################################################################################################
  get '/graphql/iql' do
    token = ""
    erb :layout, locals: {token: token}
  end

  get %r{/graphql/iql/(.*)} do
    call env.merge("PATH_INFO" => "/#{params['captures'][0]}")
  end

  #################################################################################################
  get '/chk' do
    "ok"
  end

  #################################################################################################
  def serveGraphql(params)
    content_type :json
    Thread.current[:baseURL] = request.url.sub(%r{(https?://[^/]+)(.*)}, '\1')
    Schema.execute(params['query'], variables: params['variables']).to_json
  end

  get '/graphql' do
    params['query'] or redirect(to('/graphql/iql'))
    serveGraphql params
  end

  post '/graphql' do
    serveGraphql JSON.parse(request.body.read)
  end

  #################################################################################################
  # Send a GraphQL query to the main API, returning the JSON results. Used by various wrappers
  # below (e.g. OAI and DSpace)
  def apiQuery(query, vars={})
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

  #################################################################################################
  # DSpace emulator for Symplectic Elements RT2 integration
  post %r{/dspace-rest.*} do
    serveDSpace("POST")
  end
  get %r{/dspace-rest.*} do
    serveDSpace("GET")
  end
end
