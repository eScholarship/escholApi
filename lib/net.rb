require 'net/ssh'

###################################################################################################
# Adapted From https://stackoverflow.com/questions/3386233/how-to-get-exit-status-with-rubys-netssh-library
class Net::SSH::Connection::Session
  class CommandFailed < StandardError
  end

  class CommandExecutionFailed < StandardError
  end

  def exec_sc!(command)
    stdout_data,stderr_data = "",""
    exit_code,exit_signal = nil,nil
    self.open_channel do |channel|
      channel.exec(command) do |_, success|
        success or raise(CommandExecutionFailed, "Command \"#{command}\" was unable to execute")
        channel.on_data { |_,data| stdout_data += data }
        channel.on_extended_data { |_,_,data| stderr_data += data }
        channel.on_request("exit-status") { |_,data| exit_code = data.read_long }
        channel.on_request("exit-signal") { |_, data| exit_signal = data.read_long }
      end
    end
    self.loop
    exit_code == 0 or raise(CommandFailed, "Command \"#{command}\" returned exit code #{exit_code}")
    return {
      stdout:stdout_data,
      stderr:stderr_data,
      exit_code:exit_code,
      exit_signal:exit_signal
    }
  end
end
