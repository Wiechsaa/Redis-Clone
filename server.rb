# frozen_string_literal: true

require 'socket'

# ruby -r './server' -e 'BasicServer.new'
class BasicServer
  COMMANDS = %w[GET SET].freeze

  def initialize
    @clients = []
    @data_store = {}

    server = TCPServer.new 2000
    puts "Server started at: #{Time.now}"

    loop do
      result = IO.select(@clients + [server])
      result[0].each do |socket|
        case socket
        when TCPServer
          @clients << server.accept
        when TCPSocket
          client_command_with_args = socket.read_nonblock(1024, exception: false)
          if client_command_with_args.nil?
            puts 'Found a client at eof, closing and removing'
            @clients.delete(socket)
          elsif client_command_with_args == :wait_readable
            # There's nothing to read from the client, we don't have to do anything
            next
          elsif client_command_with_args.strip.empty?
            puts "Empty request received from #{socket}"
          else
            response = handle_client_command(client_command_with_args.strip)
            socket.puts response
          end
        else
          raise "Unknown socket type: #{socket}"
        end
      end
    end
  end

  private

  def handle_client_command(client_command_with_args)
    command_parts = client_command_with_args.split
    command = command_parts[0]
    args = command_parts[1..]

    return unless COMMANDS.include?(command)

    case command
    when 'GET'
      if args.length != 1
        "(error) ERR wrong number of arguments for `#{command}` command"
      else
        @data_store.fetch(args[0], '(nil)')
      end
    when 'SET'
      if args.length != 2
        "(error) ERR wrong number of arguments for `#{command}` command"
      else
        @data_store[args[0]] = args[1]
        'OK'
      end
    else
      formatted_args = args.map { |arg| "`#{arg}`," }.join(' ')
      "(error) ERR unknown command `#{command}`, with args beginning with: #{formatted_args}"
    end
  end
end
