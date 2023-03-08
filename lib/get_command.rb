# frozen_string_literal: true

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
      "(error) ERR wrong number of arguments for 'GET' command"
    else
      key = @args[0]
      ExpireHelper.check_if_expired(@data_store, @expires, key)
      @data_store.fetch(key, '(nil)')
    end
  end
end
