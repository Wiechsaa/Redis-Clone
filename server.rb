# frozen_string_literal: true

require 'socket'

# ruby -r './server' -e 'BasicServer.new'
class BasicServer
  COMMANDS = %w[GET SET].freeze

  def initialize
    @data_store = {}

    server = TCPServer.new(2000)
    puts "Server started at: #{Time.now}"

    loop do
      client = server.accept
      puts "New client connected: #{client}"

      client_command_with_args = client.gets

      if client_command_with_args && client_command_with_args.strip.length.positive?
        response = handle_client_command(client_command_with_args)
        client.puts response
      else
        puts "Empty request recived from #{client}"
      end

      client.close
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
