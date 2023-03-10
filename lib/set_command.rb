# frozen_string_literal: true

module RedisClone
  # SET
  class SetCommand
    ValidationError = Class.new(StandardError)

    CommandOption = Struct.new(:kind)
    CommandOptionWithValue = Struct.new(:kind, :validator)

    OPTIONS = {
      'ex' => CommandOptionWithValue.new(
        'expire',
        ->(value) { validate_integer(value) * 1000 }
      ),
      'px' => CommandOptionWithValue.new(
        'expire',
        ->(value) { validate_integer(value) }
      ),
      'keepttl' => CommandOption.new('expire'),
      'nx' => CommandOption.new('presence'),
      'xx' => CommandOption.new('presence')
    }.freeze

    ERRORS = {
      'expire' => '(error) ERR value is not an integer or out of range'
    }.freeze

    def self.validate_integer(str)
      Integer(str)
    rescue ArgumentError, TypeError
      raise ValidationError, '(error) ERR value is not an integer or out of range'
    end

    def initialize(data_store, expires, args)
      @logger = Logger.new($stdout)
      @logger.level = LOG_LEVEL
      @data_store = data_store
      @expires = expires
      @args = args

      @options = {}
    end

    def call
      key, value = @args.shift(2)
      return RESPError.new("ERR wrong number of arguments for 'SET' command") if key.nil? || value.nil?

      parse_result = parse_options
      existing_key = @data_store[key]

      if @options['presence'] == 'NX' && !existing_key.nil?
        NullBulkStringInstance
      elsif @options['presence'] == 'XX' && existing_key.nil?
        NullBulkStringInstance
      else

        @data_store[key] = value
        expire_option = @options['expire']

        if expire_option.is_a? Integer
          @expires[key] = (Time.now.to_f * 1000).to_i + expire_option
        elsif expire_option.nil?
          @expires.delete(key)
        end

        OKSimpleStringInstance
      end
    rescue ValidationError => e
      RESPError.new(e.message)
    rescue SyntaxError => e
      RESPError.new(e.message)
    end

    def self.describe
      [
        'set',
        -3, # arity
        # command flags
        %w[write denyoom].map { |s| RESPSimpleString.new(s) },
        1, # position of first key in argument list
        1, # position of last key in argument list
        1, # step count for locating repeating keys
        # acl categories: https://github.com/antirez/redis/blob/6.0/src/server.c#L161-L166
        ['@write', '@string', '@slow'].map { |s| RESPSimpleString.new(s) }
      ]
    end

    private

    def parse_options
      while @args.any?
        option = @args.shift
        option_detail = OPTIONS[option.downcase]

        return '(error) ERR syntax error' unless option_detail

        option_values = parse_option_arguments(option, option_detail)
        existing_option = @options[option_detail.kind]

        return '(error) ERR syntax error' if existing_option

        @options[option_detail.kind] = option_values

      end
    end

    def parse_option_arguments(option, option_detail)
      case option_detail
      when CommandOptionWithValue
        option_value = @args.shift
        option_detail.validator.call(option_value)
      when CommandOption
        option
      else
        raise "Unknown command option type: #{option_detail}"
      end
    end
  end
end
