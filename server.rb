# frozen_string_literal: false

require 'socket'
require 'timeout'
require 'logger'

require_relative './lib/set_command'
require_relative './lib/get_command'
require_relative './lib/expire_helper'
require_relative './lib/ttl_command'
require_relative './lib/pttl_command'

LOG_LEVEL = ENV['DEBUG'] ? Logger::DEBUG : Logger::INFO

# Server
# DEBUG=true ruby -r"./server" -e "RedisServer.new"

module RedisClone
  IncompleteCommand = Class.new(StandardError)

  ProtocolError = Class.new(StandardError) do
    def serialize
      RESPError.new(message).serialize
    end
  end

  class RedisServer
    COMMANDS = {
      'command' => CommandCommand,
      'get' => GetCommand,
      'set' => SetCommand,
      'ttl' => TtlCommand,
      'pttl' => PttlCommand
    }.freeze

    MAX_EXPIRE_LOOKUPS_PER_CYCLE = 20
    DEFAULT_FREQUENCY = 10

    TimeEvent = Struct.new(:process_at, :block)

    Client = Struct.new(:socket, :buffer) do
      def initialize(socket)
        self.socket = socket
        self.buffer = ''
      end
    end

    def initialize
      @logger = Logger.new($stdout)
      @logger.level = LOG_LEVEL

      @clients = []
      @data_store = {}
      @expires = {}

      @server = TCPServer.new(2000)
      @logger.debug "Server started at: #{Time.now}"

      @time_events = []

      add_time_event(Time.now.to_f.truncate + 1) do
        server_cron
      end

      start_event_loop
    end

    private

    def start_event_loop
      loop do
        timeout = select_timeout
        @logger.debug "select with a timeout of #{timeout}"
        result = IO.select(@clients + [@server], [], [], timeout)
        sockets = result ? result[0] : []
        process_poll_events(sockets)
        process_time_events
      end
    end

    def add_time_event(process_at, &block)
      @time_events << TimeEvent.new(process_at, block)
    end

    def nearest_time_event
      now = (Time.now.to_f * 1000).truncate
      nearest = nil
      @time_events.each do |time_event|
        if nearest.nil?
          nearest = time_event
        elsif time_event.process_at < nearest.process_at
          nearest = time_event
        else
          next
        end
      end

      nearest
    end

    def select_timeout
      if @time_events.any?
        nearest = nearest_time_event
        now = (Time.now.to_f * 1000).truncate
        if nearest.process_at < now
          0
        else
          (nearest.process_at - now) / 1000.0
        end
      else
        0
      end
    end

    def process_poll_events(sockets)
      sockets.each do |socket|
        case socket
        when TCPServer
          @clients << Client.new(@server.accept)
        when TCPSocket
          client = @clients.find { |c| c.socket == socket }
          client_command_with_args = socket.read_nonblock(1024, exception: false)
          if client_command_with_args.nil?
            @clients.delete(client)
            socket.close
          elsif client_command_with_args == :wait_readable
            next
          elsif client_command_with_args.strip.empty?
            @logger.debug "Empty request received from #{client}"
          else
            client.buffer += client_command_with_args
            split_commands(client.buffer) do |command_parts|
              response = handle_client_command(command_parts)
              @logger.debug "Response: #{response.class} / #{response.inspect}"
              @logger.debug "Writing: '#{response.serialize.inspect}'"
              socket.write response.serialize
            end
          end
        else
          raise "Unknown socket type: #{socket}"
        end
      rescue Errno::ECONNRESET
        @clients.delete_if { |c| c.socket == socket }
      rescue IncompleteCommand
        # Not clearing the buffer or anything
        next
      rescue ProtocolError => e
        socket.write e.serialize
        socket.close
        @clients.delete(client)
      end
    end

    def split_commands(client_buffer)
      @logger.debug "Full result from read: '#{client_buffer.inspect}'"

      scanner = StringScanner.new(client_buffer.dup)
      until scanner.eos?
        if scanner.peek(1) == '*'
          yield parse_as_resp_array(scanner)
        else
          yield parse_as_inline_command(scanner)
        end
        client_buffer.slice!(0, scanner.charpos)
      end
    end

    def parse_as_inline_command(_client_buffer, scanner)
      command = scanner.scan_until(/(\r\n|\r|\n)+/)
      raise IncompleteCommand if command.nil?

      command.split.map(&:strip)
    end

    def parse_as_resp_array(scanner)
      raise 'Unexpectedly attempted to parse a non array as an array' unless scanner.getch == '*'

      expected_length = scanner.scan_until(/\r\n/)
      raise IncompleteCommand if expected_length.nil?

      expected_length = parse_integer(expected_length, 'invalid multibulk length')
      command_parts = []

      expected_length.times do
        raise IncompleteCommand if scanner.eos?

        parsed_value = parse_as_resp_bulk_string(scanner)
        raise IncompleteCommand if parsed_value.nil?

        command_parts << parsed_value
      end

      command_parts
    end

    def parse_integer(integer_str, error_message)
      value = Integer(integer_str)
      raise ProtocolError, "ERR Protocol error: #{error_message}" if value.negative?

      value
    rescue ArgumentError
      raise ProtocolError, "ERR Protocol error: #{error_message}"
    end

    def parse_as_resp_bulk_string(scanner)
      type_char = scanner.getch
      raise ProtocolError, "ERR Protocol error: expected '$', got '#{type_char}'" unless type_char == '$'

      expected_length = scanner.scan_until(/\r\n/)
      raise IncompleteCommand if expected_length.nil?

      expected_length = parse_integer(expected_length, 'invalid bulk length')
      bulk_string = scanner.rest.slice(0, expected_length)

      raise IncompleteCommand if bulk_string.nil? || bulk_string.length != expected_length

      scanner.pos += bulk_string.bytesize + 2
      bulk_string
    end

    def process_time_events
      @time_events.delete_if do |time_event|
        next if time_event.process_at > Time.now.to_f * 1000

        return_value = time_event.block.call

        if return_value.nil?
          true
        else
          time_event.process_at = (Time.now.to_f * 1000).truncate + return_value
          @logger.debug "Rescheduling time event #{Time.at(time_event.process_at / 1000.0).to_f}"
          false
        end
      end
    end

    def handle_client_command(command_parts)
      @logger.debug "Received command: #{command_parts}"
      command_str = command_parts[0]
      args = command_parts[1..]

      command_class = COMMANDS[command_str.downcase]

      if command_class
        command = command_class.new(@data_store, @expires, args)
        command.call
      else
        formatted_args = args.map { |arg| "`#{arg}`," }.join(' ')
        "(error) ERR unknown command `#{command_str}`, with args beginning with: #{formatted_args}"
      end
    end

    def server_cron
      start_timestamp = Time.now
      keys_fetched = 0

      @expires.each do |key, _|
        if @expires[key] < Time.now.to_f * 1000
          @logger.debug "Evicting #{key}"
          @expires.delete(key)
          @data_store.delete(key)
        end

        keys_fetched += 1
        break if keys_fetched >= MAX_EXPIRE_LOOKUPS_PER_CYCLE
      end

      end_timestamp = Time.now
      @logger.debug do
        format(
          'Processed %<keys_fetched>i keys in %<time>.3f ms',
          keys_fetched: keys_fetched,
          time: (end_timestamp - start_timestamp) * 1000
        )
      end

      1000 / DEFAULT_FREQUENCY
    end
  end
end
