require_relative './access/oai.rb'
require_relative './access/rss.rb'
require_relative "./access/accessSchema.rb"
require_relative "./submit/submitSchema.rb"

# On dev and stg we control access with a special cookie
ACCESS_COOKIE = (ENV['ACCESS_COOKIE'] || '').empty? ? nil : ENV['ACCESS_COOKIE']

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
    puts str
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
    return true
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
class EscholSchema < GraphQL::Schema
  query AccessQueryType
  mutation SubmitMutationType
  use GraphQL::Batch
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
  response = EscholSchema.execute(query, variables: varHash)
  response['errors'] and raise("Internal error (graphql): #{response['errors'][0]['message']}")
  response['data']
end

###################################################################################################
class EscholAPI < Sinatra::Base
  set public_folder: 'public', static: true
  set show_exceptions: false
  set views: settings.root + "/../views"

  # Replace Sinatra's normal logging with one that goes to our overridden stdout puts, so we
  # can include the pid and thread number with each request.
  #set :logging, false
  #disable :logging
  use AccessLogger, $stdoutLogger

   # Compress things that can benefit
  use Rack::Deflater,
    :if => lambda { |env, status, headers, body|
      # advice from https://www.itworld.com/article/2693941/cloud-computing/
      #                why-it-doesn-t-make-sense-to-gzip-all-content-from-your-web-server.html
      return headers["Content-Length"].to_i > 1400
    }

  #################################################################################################
  # A few properties privileged properties are needed by the RT2 connector, and there's a special
  # HTTP header to pass the API key in.
  def checkPrivilegedHdr
    hdr = request.env['HTTP_PRIVILEGED'] or return false
    privKey = ENV['ESCHOL_PRIV_API_KEY'] or raise("missing env ESCHOL_PRIV_API_KEY")
    hdr.strip == privKey or halt(403, "Incorrect API key")
    return true
  end

  #################################################################################################
  # Add some URL context so stuff deep in the GraphQL schema can get to it
  before do
    ENV['ALLOWED_IPS'] && !Regexp.new(ENV['ALLOWED_IPS']).match(request.ip) and halt(403)
    ENV['BLOCKED_IPS'] && Regexp.new(ENV['BLOCKED_IPS']).match(request.ip) and halt(403)
    Thread.current[:baseURL] = request.url.sub(%r{(https?://[^/:]+)(.*)}, '\1')
    Thread.current[:path] = request.path
    Thread.current[:privileged] = checkPrivilegedHdr

    # On dev and stg, control access with a special cookie
    if ACCESS_COOKIE
      if request.params['access']
        response.set_cookie(:ACCESS_COOKIE, :value => request.params['access'], :path => "/")
        ACCESS_COOKIE == request.params['access'] or halt(401, "Not authorized.")
      elsif request.path != "/chk"
        ACCESS_COOKIE == request.cookies['ACCESS_COOKIE'] or halt(401, "Not authorized.")
      end
    end
  end

  after do
    Thread.current[:baseURL] = nil
    Thread.current[:path] = nil
    Thread.current[:privileged] = nil
  end

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
  # Error handling - include call stack for upper layers to report
  error 500 do
    e = env['sinatra.error']
    content_type "text/plain"
    return "Unhandled exception: #{e.message}\n" +
           "eSchol API backtrace:\n" +
           "\t#{e.backtrace.join("\n\t")}\n"
  end

  #################################################################################################
  def serveGraphql(params)
    content_type :json
    headers "Access-Control-Allow-Origin" => "*"
    if params['query'] =~ /\bmutation\s*\(/i && !Thread.current[:privileged]
      halt(403) # all mutations must be privileged
    end
    EscholSchema.execute(params['query'],
                         variables: params['variables']).to_json
  end

  get '/graphql' do
    params['query'] or redirect(to('/graphql/iql'))
    serveGraphql params
  end

  post '/graphql' do
    serveGraphql JSON.parse(request.body.read)
  end

  options '/graphql' do
    headers "Access-Control-Allow-Origin" => "*"
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
