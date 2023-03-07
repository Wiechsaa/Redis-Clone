# frozen_string_literal: true

require 'socket'

class BasicClient
  COMMANDS = %w[GET SET].freeze

  def get(key)
    socket = TCPSocket.new('localhost', 2000)
    socket.puts "GET #{key}"
    result = socket.gets
    socket.close
    result
  end

  def set(key, value)
    socket = TCPSocket.new('localhost', 2000)
    socket.puts "SET #{key} #{value}"
    result = socket.gets
    socket.close
    result
  end
end
