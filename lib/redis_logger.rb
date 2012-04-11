require 'redis'

#
# redis_logger
# http://github.com/masonoise/redis_logger
#
# Enable logging into redis database, with support for grouping log entries into one or more
# groups.
#
# Log entries are stored in redis using keys of the form: log:<timestamp> with timestamp being
# a longint representation of the time. Log entries are then also added to a set associated
# with the log level, and then with any other sets specified in a list of "log groups".
#
# A set is maintained with the list of all of the groups: "logger:sets". Each group is
# represented by a set called "logger:set:<name>" where name is the group name.
#
class RedisLogger

  def self.redis=(server)
    host, port, db = server.split(':')
    @redis = Redis.new(:host => host, :port => port, :thread_safe => true, :db => db)
  end

  def self.redis
    return @redis if @redis
    self.redis = 'localhost:6379'
    self.redis
  end

  #
  # Provide standard methods for various log levels. Each just calls the private
  # add_entry() method passing in its level name to use as the group name.
  #
  # For each, the log_entry is a Hash of items to include in the log, and sets is
  # either a string or an array of strings, which are the groups into which the
  # entry will be added (in addition to the standard log level group).
  #

  def self.debug(log_entry, sets = nil)
    add_entry(log_entry, "debug", sets)
  end


  def self.warn(log_entry, sets = nil)
    add_entry(log_entry, "warn", sets)
  end

  # Standard method for error messages. See comment above about debug()
  def self.error(log_entry, sets = nil)
    add_entry(log_entry, "error", sets)
  end

  #
  # Utility methods, mainly used by the web interface to display the lists of
  # groups and entries.
  #

  #
  # Get the list of all of the log groups that exist.
  #
  def self.groups
    group_keys = redis.smembers "logger:sets"
    groups = {}
    group_keys.each do |k|
      groups[k] = redis.scard("logger:set:#{k}")
    end
    return groups
  end

  # How many entries are in the specified log group?
  def self.size(group)
    redis.scard("logger:set:#{group}")
  end

  #
  # Get the entries from a log group, with optional start index and per_page count,
  # which default to 0/50 if not specified. Entries are returned in reverse order,
  # most recent to oldest.
  #
  def self.entries(group, start=0, per_page=50)
    entry_list = redis.sort("logger:set:#{group}", { :limit => [ start, per_page ], :order => "DESC" })
    fetch_entries(entry_list)
  end

  #
  # Get the entries for an intersection of groups. Takes an array of group names and
  # returns the top 100 resulting entries. This is done by intersecting into a new set,
  # fetching the first 100 entries, then deleting the set.
  # TODO: Save the intersected set, allow paginating, and use a cron to delete the temp sets
  #
  def self.intersect(groups)
    counter = redis.incrby("logger:index", 1)
    redis.sinterstore("logger:inter:#{counter}", groups.collect {|g| "logger:set:#{g}"})
    entry_list = redis.sort("logger:inter:#{counter}", { :limit => [ 0, 100 ], :order => "DESC" })
    entries = fetch_entries(entry_list)
    redis.del("logger:inter:#{counter}")
    return entries
  end

  #
  # Utility method to fetch entries given an array returned from a group set.
  #
  def self.fetch_entries(entry_list)
    entries = []
    entry_list.each do |e|
      entries << redis.hgetall("log:#{e}")
    end
    return entries
  end


  private

  #
  # Add the log entry. The level is passed in separately rather than being merged with the
  # other sets just in case we want to treat it differently in the future.
  #
  def self.add_entry(log_entry, level, sets = nil)
    # TODO: Need to add unique id to timestamp to prevent multiple servers from causing collisions
    tstamp = Time.now.to_i
    log_entry["timestamp"] = tstamp
    log_entry.each { |key, value| redis.hset "log:#{tstamp}", key, value }
    # hmset() seems to be broken so skip it for now. Could pipeline the above commands.
    #redis.hmset tstamp, *(log_entry.to_a)

    # Add entry to the proper log-level set, and desired group sets if any
    case sets.class
      when 'String'
        sets = [sets]
      when 'NilClass'
        sets = []
    end
    # TODO: Shouldn't need to add the level every time; could do it once at startup?
    redis.sadd "logger:sets", level
    redis.sadd "logger:set:#{level}", tstamp
    sets.each do |set|
      redis.sadd "logger:sets", set
      redis.sadd "logger:set:#{set}", tstamp
    end
  end
end
