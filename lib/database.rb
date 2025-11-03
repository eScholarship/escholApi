def waitForSocks(host, port)
  begin
    sock = TCPSocket.new(host, port)
    sock.close
  rescue Errno::ECONNREFUSED
    retries ||= 0
    retries == 0 and puts("Waiting for SOCKS proxy to start.")
    retries += 1
    if retries == 60 # == 30 sec
      puts "SOCKS proxy failed. Verify that 'ssh yourUsername@pub-jschol-dev.escholarship.org' works."
      exit 1
    else
      sleep 0.5
      retry
    end
  end
end

def ensureConnect(envPrefix)
  Sequel.default_timezone=:local
  dbConfig = { "adapter"  => "mysql2",
               "host"     => ENV["#{envPrefix}_HOST"] || raise("missing env #{envPrefix}_HOST"),
               "port"     => ENV["#{envPrefix}_PORT"] || raise("missing env #{envPrefix}_PORT").to_i,
               "database" => ENV["#{envPrefix}_DATABASE"] || raise("missing env #{envPrefix}_DATABASE"),
               "username" => ENV["#{envPrefix}_USERNAME"] || raise("missing env #{envPrefix}_USERNAME"),
               "password" => ENV["#{envPrefix}_PASSWORD"] || raise("missing env #{envPrefix}_HOST"),
               "max_connections" => 10,
               "pool_timeout" => 10 }
  if TCPSocket::socks_port
    SocksMysql.new(dbConfig)
  end
  db = Sequel.connect(dbConfig)
  n = db.fetch("SHOW TABLE STATUS").all.length
  n > 0 or raise("Failed to connect to db.")
  return db
end

# Use the Sequel gem to get object-relational mapping, connection pooling, thread safety, etc.
# If specified, use SOCKS proxy for all connections (including database).
if ENV['SOCKS_PORT']
  # Configure socksify for all TCP connections. Jump through hoops for MySQL to use it too.
  require 'maybeSocks'
  require 'socksify'
  socksPort = ENV['SOCKS_PORT']
  waitForSocks("127.0.0.1", socksPort)
  TCPSocket::socks_server = "127.0.0.1"
  TCPSocket::socks_port = socksPort
  require 'socksMysql'
end
puts "Connecting to eschol DB."
DB = ensureConnect("ESCHOL_DB")
puts "Connected."

