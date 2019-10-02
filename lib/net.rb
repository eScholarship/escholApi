require 'net/ssh'

###################################################################################################
# Adapted From https://stackoverflow.com/questions/3386233/how-to-get-exit-status-with-rubys-netssh-library
class Net::SSH::Connection::Session
  class CommandFailed < StandardError
  end

  class CommandExecutionFailed < StandardError
  end

  def exec_sc!(command, input = nil)
    stdout_data,stderr_data = "",""
    exit_code,exit_signal = nil,nil
    self.open_channel do |channel|
      puts "Executing command #{command.inspect}"
      channel.exec(command) do |_, success|
        if input
          channel.send_data(input)
          channel.eof!
        end
        success or raise(CommandExecutionFailed, "Command \"#{command}\" was unable to execute")
        channel.on_data { |_,data| stdout_data += data }
        channel.on_extended_data { |_,_,data| stderr_data += data }
        channel.on_request("exit-status") { |_,data| exit_code = data.read_long }
        channel.on_request("exit-signal") { |_, data| exit_signal = data.read_long }
      end
    end
    self.loop
    puts "Done executing command. exit_code=#{exit_code}"
    if exit_code != 0
      raise(CommandFailed, "Command \"#{command}\" exited with code #{exit_code}. " +
                           "Full stderr:\n  #{stderr_data}" +
                           "Full stdout:\n  #{stdout_data}")
    end
    return {
      stdout:stdout_data,
      stderr:stderr_data,
      exit_code:exit_code,
      exit_signal:exit_signal
    }
  end
end
