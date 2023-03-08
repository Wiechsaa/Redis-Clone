# frozen_string_literal: true

module RedisClone
  # GET
  class GetCommand
    def initialize(data_store, expires, args)
      @logger = Logger.new($stdout)
      @logger.level = LOG_LEVEL
      @data_store = data_store
      @expires = expires
      @args = args
    end

    def call
      if @args.length != 1
        RESPError.new("ERR wrong number of arguments for 'GET' command")
      else
        key = @args[0]
        ExpireHelper.check_if_expired(@data_store, @expires, key)
        value = @data_store[key]
        if value.nil?
          NullBulkStringInstance
        else
          RESPBulkString.new(value)
        end
      end
    end
  end

  def self.describe
    [
      'get',
      2, # arity
      # command flags
      %w[readonly fast].map { |s| RESPSimpleString.new(s) },
      1, # position of first key in argument list
      1, # position of last key in argument list
      1, # step count for locating repeating keys
      # acl categories: https://github.com/antirez/redis/blob/6.0/src/server.c#L161-L166
      ['@read', '@string', '@fast'].map { |s| RESPSimpleString.new(s) }
    ]
  end
end
