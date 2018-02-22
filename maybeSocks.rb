#!/usr/bin/env ruby

require 'socket'

verbose = ARGV.delete('-v') || ARGV.delete('--verbose')

# If there's no socks config, definitely don't start socks.
if !ENV['SOCKS_PORT']
  verbose and puts "No SOCKS proxy configured, so not starting one."
  exit(0)
end

# See if there's already a proxy listening on the specified port
port = ENV['SOCKS_PORT'].to_i
needSocks = true
begin
  s = TCPSocket.open("127.0.0.1", port)
  s.close()
  verbose and puts "SOCKS proxy already running on port #{port}."
  needSocks = false
rescue
  # ok, good, we can't connect
end

if needSocks
  targetMachine = ENV['SOCKS_TARGET'] || raise("missing env SOCKS_TARGET")

  bastion = ENV['SOCKS_BASTION']
  bastionPort = ENV['SOCKS_BASTION_PORT']

  # Fire up a proxy, optionally overriding username
  puts "\nStarting SOCKS proxy."
  user = ENV['SOCKS_USER'] ? "#{ENV['SOCKS_USER']}@" : ""
  cmd = "ssh -N -D #{port} " +
        "-F /dev/null " +
        "#{bastion ? "-o ProxyCommand='ssh -C -W %h:%p -o StrictHostKeyChecking=no -o CheckHostIP=no #{bastionPort ? "-p #{bastionPort}" : ""} #{user}cdl-aws-bastion.cdlib.org' " : ""}" +
        "-o StrictHostKeyChecking=no " +
        "-o CheckHostIP=no " +
        "#{user}#{targetMachine}"
  puts cmd
  pid = spawn(cmd)
  Process.detach(pid)
end