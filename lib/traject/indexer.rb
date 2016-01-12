require 'yell'

require 'traject'
require 'traject/qualified_const_get'
require 'traject/thread_pool'

require 'traject/indexer/settings'
require 'traject/marc_reader'
require 'traject/json_writer'
require 'traject/solr_json_writer'
require 'traject/debug_writer'


require 'traject/macros/marc21'
require 'traject/macros/basic'

if defined? JRUBY_VERSION
  require 'traject/marc4j_reader'
end

# This class does indexing for traject: Getting input records from a Reader
# class, mapping the input records to an output hash, and then sending the output
# hash off somewhere (usually Solr) with a Writer class.
#
# Traject config files are `instance_eval`d in an Indexer object, so `self` in
# a config file is an Indexer, and any Indexer methods can be called.
#
# However, certain Indexer methods exist mainly for the purpose of
# being called in config files; these methods are part of the expected
# Domain-Specific Language ("DSL") for config files, and will ordinarily
# form the bulk or entirety of config files:
#
# * #settings
# * #to_field
# * #each_record
# * #after_procesing
# * #logger (rarely used in config files, but in some cases to set up custom logging config)
#
#  ## Readers and Writers
#
#  The Indexer has a modularized architecture for readers and writers, for where
#  source records come from (reader), and where output is sent to (writer).
#
#  A Reader is any class that:
#   1) Has a two-argument initializer taking an IO stream and a Settings hash
#   2) Responds to the usual ruby #each, returning a source record from each #each.
#      (Including Enumerable is prob a good idea too)
#
#  The default reader is the Traject::MarcReader, who's behavior is
#  further customized by several settings in the Settings hash. Jruby users
#  with specialized needs may want to look at the gem traject-marc4j_reader.
#
#  Alternate readers can be set directly with the #reader_class= method, or
#  with the "reader_class_name" Setting, a String name of a class
#  meeting the reader contract.
#
#
#  A Writer is any class that:
#  1) Has a one-argument initializer taking a Settings hash. (The logger
#     is provided to the Writer in settings["logger"])
#  2) Responds to a one argument #put method, where the argument is
#     a Traject::Indexer::Context, containing an #output_hash
#     hash of mapped keys/values. The writer should write them
#     to the appropriate place.
#  3) Responds to a #close method, called when we're done.
#  4) Optionally implements a #skipped_record_count method, returning int count of records
#     that were skipped due to errors (and presumably logged)
#
#  Traject packages one solr writer: traject/solr_json_writer, which sends
#  in json format and works under both ruby and  jruby, but only with solr version
#  >= 3.2. To index to an older solr installation, you'll need to use jruby and
#  install the gem traject-solrj_writer, which uses the solrj .jar underneath.
#
#  You can set alternate writers by setting a Class object directly
#  with the #writer_class method, or by the 'writer_class_name' Setting,
#  with a String name of class meeting the Writer contract. There are several
#  that ship with traject itself:
#
#  * traject/json_writer (Traject::JsonWriter) -- write newline-delimied json files.
#  * traject/yaml_writer (Traject::YamlWriter) -- write pretty yaml file; very human-readable
#  * traject/debug_writer (Traject::DebugWriter) -- write a tab-delimited file where
#    each line consists of the id, field, and value(s).
#  * traject/delimited_writer and traject/csv_writer -- write character-delimited files
#    (default is tab-delimited) or comma-separated-value files.
#
# ## Creating and Using an Indexer programmatically
#
# Normally the Traject::Indexer is created and used by a Traject::Command object.
# However, you can also create and use a Traject::Indexer programmatically, for embeddeding
# in your own ruby software. (Note, you will get best performance under Jruby only)
#
#      indexer = Traject::Indexer.new
#
# You can load a config file from disk, using standard ruby `instance_eval`.
# One benefit of loading one or more ordinary traject config files saved separately
# on disk is that these config files could also be used with the standard
# traject command line.
#
#      indexer.load_config_file(path_to_config)
#
# This may raise if the file is not readable. Or if the config file
# can't be evaluated, it will raise a Traject::Indexer::ConfigLoadError
# with a bunch of contextual information useful to reporting to developer.
#
# You can also instead, or in addition, write configuration inline using
# standard ruby `instance_eval`:
#
#     indexer.instance_eval do
#        to_field "something", literal("something")
#        # etc
#     end
#
# Or even load configuration from an existing lambda/proc object:
#
#     config = proc do
#       to_field "something", literal("something")
#     end
#     indexer.instance_eval &config
#
# It is least confusing to provide settings after you load
# config files, so you can determine if your settings should
# be defaults (taking effect only if not provided in earlier config),
# or should force themselves, potentially overwriting earlier config:
#
#      indexer.settings do
#         # default, won't overwrite if already set by earlier config
#         provide "solr.url", "http://example.org/solr"
#         provide "reader", "Traject::MarcReader"
#
#         # or force over any previous config
#         store "solr.url", "http://example.org/solr"
#      end
#
# Once your indexer is set up, you could use it to transform individual
# input records to output hashes. This method will ignore any readers
# and writers, and won't use thread pools, it just maps. Under
# standard MARC setup, `record` should be a `MARC::Record`:
#
#      output_hash = indexer.map_record(record)
#
# Or you could process an entire stream of input records from the
# configured reader, to the configured writer, as the traject command line
# does:
#
#      indexer.process(io_stream)
#      # or, eg:
#      File.open("path/to/input") do |file|
#        indexer.process(file)
#      end
#
# At present, you can only call #process _once_ on an indexer,
# but let us know if that's a problem, we could enhance.
#
# Please do let us know if there is some part of this API that is
# inconveient for you, we'd like to know your use case and improve things.
#
class Traject::Indexer

  # Arity error on a passed block
  class ArityError < ArgumentError; end
  class NamingError < ArgumentError; end



  include Traject::QualifiedConstGet

  attr_writer :reader_class, :writer_class, :writer

  # For now we hard-code these basic macro's included
  # TODO, make these added with extend per-indexer,
  # added by default but easily turned off (or have other
  # default macro modules provided)
  include Traject::Macros::Marc21
  include Traject::Macros::Basic


  # optional hash or Traject::Indexer::Settings object of settings.
  def initialize(arg_settings = {})
    @settings = Settings.new(arg_settings)
    @index_steps = []
    @after_processing_steps = []
  end

  # Pass a string file path, or a File object, for
  # a config file to load into indexer.
  #
  # Can raise:
  # * Errno::ENOENT or Errno::EACCES if file path is not accessible
  # * Traject::Indexer::ConfigLoadError if exception is raised evaluating
  #   the config. A ConfigLoadError has information in it about original
  #   exception, and exactly what config file and line number triggered it.
  def load_config_file(file_path)
    File.open(file_path) do |file|
      begin
        self.instance_eval(file.read, file_path)
      rescue ScriptError, StandardError => e
        raise ConfigLoadError.new(file_path, e)
      end
    end
  end

  # Part of the config file DSL, for writing settings values.
  #
  # The Indexer's settings consist of a hash-like Traject::Settings
  # object. The settings hash is *not*  nested hashes, just one level
  # of configuration settings. Keys are always strings, and by convention
  # use "." for namespacing, eg `log.file`
  #
  # The settings method with no arguments returns that Settings object.
  #
  # With a hash and/or block argument, can be used to set
  # new key/values. Each call merges onto the existing settings
  # hash.  The block is `instance_eval`d in the context
  # of the Traject::Settings object.
  #
  #    indexer.settings("a" => "a", "b" => "b")
  #
  #    indexer.settings do
  #      provide "b", "new b"
  #    end
  #
  #    indexer.settings #=> {"a" => "a", "b" => "new b"}
  #
  # Note the #provide method is defined on Traject::Settings to
  # write to a setting only if previously not set. You can also
  # use #store to force over-writing even if an existing setting.
  #
  # Even with arguments, Indexer#settings returns the Settings object,
  # hash too, so can method calls can be chained.
  #
  def settings(new_settings = nil, &block)
    @settings.merge!(new_settings) if new_settings

    @settings.instance_eval &block if block

    return @settings
  end

  # Part of DSL, used to define an indexing mapping. Register logic
  # to be called for each record, and generate values for a particular
  # output field.
  def to_field(field_name, aLambda = nil, &block)
    @index_steps << ToFieldStep.new(field_name, aLambda, block, Traject::Util.extract_caller_location(caller.first) )
  end

  # Part of DSL, register logic to be called for each record
  def each_record(aLambda = nil, &block)
    @index_steps << EachRecordStep.new(aLambda, block, Traject::Util.extract_caller_location(caller.first) )
  end

  # Part of DSL, register logic to be called once at the end
  # of processing a stream of records.
  def after_processing(aLambda = nil, &block)
    @after_processing_steps << AfterProcessingStep.new(aLambda, block, Traject::Util.extract_caller_location(caller.first))
  end

  def logger
    @logger ||= create_logger
  end
  attr_writer :logger


  def logger_format
    format = settings["log.format"] || "%d %5L %m"
    format = case format
      when "false" then false
      when "" then nil
      else format
    end
  end

  # Create logger according to settings
  def create_logger

    logger_level  = settings["log.level"] || "info"

    # log everything to STDERR or specified logfile
    logger = Yell::Logger.new(:null)
    logger.format = logger_format
    logger.level  = logger_level

    logger_destination = settings["log.file"] || "STDERR"
    # We intentionally repeat the logger_level
    # on the adapter, so it will stay there if overall level
    # is changed.
    case logger_destination
    when "STDERR"
      logger.adapter :stderr, level: logger_level, format: logger_format
    when "STDOUT"
      logger.adapter :stdout, level: logger_level, format: logger_format
    else
      logger.adapter :file, logger_destination, level: logger_level, format: logger_format
    end


    # ADDITIONALLY log error and higher to....
    if settings["log.error_file"]
      logger.adapter :file, settings["log.error_file"], :level => 'gte.error'
    end

    return logger
  end

  # Processes a single record according to indexing rules set up in
  # this indexer. Returns the output hash (a hash whose keys are
  # string fields, and values are arrays of one or more values in that field)
  #
  # This is a convenience shortcut for #map_to_context! -- use that one
  # if you want to provide addtional context
  # like position, and/or get back the full context.
  def map_record(record)
    context = Context.new(:source_record => record, :settings => settings)
    map_to_context!(context)
    return context.output_hash
  end

  # Maps a single record INTO the second argument, a Traject::Indexer::Context.
  #
  # Context must be passed with a #source_record and #settings, and optionally
  # a #position.
  #
  # Context will be mutated by this method, most significantly by adding
  # an #output_hash, a hash from fieldname to array of values in that field.
  #
  # Pass in a context with a set #position if you want that to be available
  # to mapping routines.
  #
  # Returns the context passed in as second arg, as a convenience for chaining etc.

  def map_to_context!(context)
    @index_steps.each do |index_step|
      # Don't bother if we're skipping this record
      break if context.skip?

      context.index_step = index_step
      accumulator = log_mapping_errors(context, index_step) do
        index_step.execute(context) # will always return [] for an each_record step
      end

      if accumulator.size > 0
        accumulator.compact!
        (context.output_hash[index_step.field_name] ||= []).concat accumulator
      end

      context.index_step = nil
    end

    return context
  end

  # just a wrapper that captures and records any unexpected
  # errors raised in mapping, along with contextual information
  # on record and location in source file of mapping rule.
  #
  # Re-raises error at the moment.
  #
  # log_mapping_errors(context, index_step) do
  #    all_sorts_of_stuff # that will have errors logged
  # end
  def log_mapping_errors(context, index_step)
    begin
      yield
    rescue Exception => e
      msg =  "Unexpected error on record id `#{context.source_record_id}` at file position #{context.position}\n"
      msg += "    while executing #{index_step.inspect}\n"
      msg += Traject::Util.exception_to_log_message(e)

      logger.error msg
      begin
        logger.debug "Record: " + context.source_record.to_s
      rescue Exception => marc_to_s_exception
        logger.debug "(Could not log record, #{marc_to_s_exception})"
      end

      raise e
    end
  end


  # Processes a stream of records, reading from the configured Reader,
  # mapping according to configured mapping rules, and then writing
  # to configured Writer.
  #
  # returns 'false' as a signal to command line to return non-zero exit code
  # for some reason (reason found in logs, presumably). This particular mechanism
  # is open to complexification, starting simple. We do need SOME way to return
  # non-zero to command line.
  #
  def process(io_stream)
    settings.fill_in_defaults!

    count      =       0
    start_time = batch_start_time = Time.now
    logger.debug "beginning Indexer#process with settings: #{settings.inspect}"

    reader = self.reader!(io_stream)

    processing_threads = settings["processing_thread_pool"].to_i
    thread_pool = Traject::ThreadPool.new(processing_threads)

    logger.info "   Indexer with #{processing_threads} processing threads, reader: #{reader.class.name} and writer: #{writer.class.name}"

    log_batch_size = settings["log.batch_size"] && settings["log.batch_size"].to_i

    reader.each do |record; position|
      count += 1

      # have to use a block local var, so the changing `count` one
      # doesn't get caught in the closure. Weird, yeah.
      position = count

      thread_pool.raise_collected_exception!

      if settings["debug_ascii_progress"].to_s == "true"
        $stderr.write "." if count % settings["solr_writer.batch_size"].to_i == 0
      end

      context = Context.new(
        :source_record => record,
        :settings => settings,
        :position => position,
        :logger => logger
      )

      if log_batch_size && (count % log_batch_size == 0)
        batch_rps = log_batch_size / (Time.now - batch_start_time)
        overall_rps = count / (Time.now - start_time)
        logger.send(settings["log.batch_size.severity"].downcase.to_sym, "Traject::Indexer#process, read #{count} records at id:#{context.source_record_id}; #{'%.0f' % batch_rps}/s this batch, #{'%.0f' % overall_rps}/s overall")
        batch_start_time = Time.now
      end

      # We pass context in a block arg to properly 'capture' it, so
      # we don't accidentally share the local var under closure between
      # threads.
      thread_pool.maybe_in_thread_pool(context) do |context|
        map_to_context!(context)
        if context.skip?
          log_skip(context)
        else
          writer.put context
        end

      end

    end
    $stderr.write "\n" if settings["debug_ascii_progress"].to_s == "true"

    logger.debug "Shutting down #processing mapper threadpool..."
    thread_pool.shutdown_and_wait
    logger.debug "#processing mapper threadpool shutdown complete."

    thread_pool.raise_collected_exception!


    writer.close if writer.respond_to?(:close)

    @after_processing_steps.each do |step|
      begin
        step.execute
      rescue Exception => e
        logger.fatal("Unexpected exception #{e} when executing #{step}")
        raise e
      end
    end

    elapsed        = Time.now - start_time
    avg_rps        = (count / elapsed)
    logger.info "finished Indexer#process: #{count} records in #{'%.3f' % elapsed} seconds; #{'%.1f' % avg_rps} records/second overall."

    if writer.respond_to?(:skipped_record_count) && writer.skipped_record_count > 0
      logger.error "Indexer#process returning 'false' due to #{writer.skipped_record_count} skipped records."
      return false
    end

    return true
  end

  # Log that the current record is being skipped, using
  # data in context.position and context.skipmessage
  def log_skip(context)
    logger.debug "Skipped record #{context.position}: #{context.skipmessage}"
  end

  def reader_class
    unless defined? @reader_class
      @reader_class = qualified_const_get(settings["reader_class_name"])
    end
    return @reader_class
  end

  def writer_class
    writer.class
  end

  # Instantiate a Traject Reader, using class set
  # in #reader_class, initialized with io_stream passed in
  def reader!(io_stream)
    return reader_class.new(io_stream, settings.merge("logger" => logger))
  end

  # Instantiate a Traject Writer, suing class set in #writer_class
  def writer!
    writer_class = @writer_class || qualified_const_get(settings["writer_class_name"])
    writer_class.new(settings.merge("logger" => logger))
  end

  def writer
    @writer ||= settings["writer"] || writer!
  end

  # Represents the context of a specific record being indexed, passed
  # to indexing logic blocks
  #
  class Context
    def initialize(hash_init = {})
      # TODO, argument checking for required args?

      self.clipboard   = {}
      self.output_hash = {}

      hash_init.each_pair do |key, value|
        self.send("#{key}=", value)
      end

      @skip = false
    end

    attr_accessor :clipboard, :output_hash, :logger
    attr_accessor :index_step, :source_record, :settings
    # 1-based position in stream of processed records.
    attr_accessor :position

    # Should we be skipping this record?
    attr_accessor :skipmessage

    # Set the fact that this record should be skipped, with an
    # optional message
    def skip!(msg = '(no message given)')
      @skipmessage = msg
      @skip = true
    end

    # Should we skip this record?
    def skip?
      @skip
    end

    # Useful for describing a record in a log or especially
    # error message. May be useful to combine with #position
    # in output messages, especially since this method may sometimes
    # return empty string if info on record id is not available.
    #
    # Returns MARC 001, then a slash, then output_hash["id"] -- if both
    # are present. Otherwise may return just one, or even an empty string.
    #
    # Likely override this for a future XML or other source format version.
    def source_record_id
      marc_id = if self.source_record &&
                   self.source_record.kind_of?(MARC::Record) &&
                   self.source_record['001']
        self.source_record['001'].value
      end
      output_id = self.output_hash["id"]

      return [marc_id, output_id].compact.join("/")
    end

  end



  # An indexing step definition, including it's source location
  # for logging
  #
  # This one represents an "each_record" step, a subclass below
  # for "to_field"
  #
  # source_location is just a string with filename and line number for
  # showing to devs in debugging.
  class EachRecordStep
    attr_accessor :source_location, :lambda, :block

    def initialize(lambda, block, source_location)
      self.lambda = lambda
      self.block = block
      self.source_location = source_location

      self.validate!
    end

    # raises if bad data
    def validate!
      unless self.lambda or self.block
        raise ArgumentError.new("Missing Argument: each_record must take a block/lambda as an argument (#{self.inspect})")
      end

      [self.lambda, self.block].each do |proc|
        # allow negative arity, meaning variable/optional, trust em on that.
        # but for positive arrity, we need 1 or 2 args
        if proc
          unless proc.is_a?(Proc)
            raise NamingError.new("argument to each_record must be a block/lambda, not a #{proc.class} #{self.inspect}")
          end
          if (proc.arity == 0 || proc.arity > 2)
            raise ArityError.new("block/proc given to each_record needs 1 or 2 arguments: #{self.inspect}")
          end
        end
      end
    end

    # For each_record, always return an empty array as the
    # accumulator, since it doesn't have those kinds of side effects
    def execute(context)
      [@lambda, @block].each do |aProc|
        next unless aProc

        if aProc.arity == 1
          aProc.call(context.source_record)
        else
          aProc.call(context.source_record, context)
        end

      end
      return [] # empty -- no accumulator for each_record
    end

    # Over-ride inspect for outputting error messages etc.
    def inspect
      "(each_record at #{source_location})"
    end
  end


  # An indexing step definition for a "to_field" step to specific
  # field.
  class ToFieldStep
    attr_accessor :field_name, :lambda, :block, :source_location
    def initialize(fieldname, lambda, block, source_location)
      self.field_name = fieldname
      self.lambda = lambda
      self.block = block
      self.source_location = source_location

      validate!
    end

    def validate!

      if self.field_name.nil? || !self.field_name.is_a?(String) || self.field_name.empty?
        raise NamingError.new("to_field requires the field name (as a string) as the first argument at #{self.source_location})")
      end

      [self.lambda, self.block].each do |proc|
        # allow negative arity, meaning variable/optional, trust em on that.
        # but for positive arrity, we need 2 or 3 args
        if proc && (proc.arity == 0 || proc.arity == 1 || proc.arity > 3)
          raise ArityError.new("error parsing field '#{self.field_name}': block/proc given to to_field needs 2 or 3 (or variable) arguments: #{proc} (#{self.inspect})")
        end
      end
    end

    # Override inspect for developer debug messages
    def inspect
      "(to_field #{self.field_name} at #{self.source_location})"
    end

    def execute(context)
      accumulator = []
      [@lambda, @block].each do |aProc|
        next unless aProc

        if aProc.arity == 2
          aProc.call(context.source_record, accumulator)
        else
          aProc.call(context.source_record, accumulator, context)
        end

      end
      return accumulator
    end

  end

  # A class representing a block of logic called after
  # processing, registered with #after_processing
  class AfterProcessingStep
    attr_accessor :lambda, :block, :source_location
    def initialize(lambda, block, source_location)
      self.lambda = lambda
      self.block = block
      self.source_location = source_location
    end

    # after_processing steps get no args yielded to
    # their blocks, they just are what they are.
    def execute
      [lambda, block].each do |aProc|
        next unless aProc
        aProc.call
      end
    end

    def inspect
      "(after_processing at #{self.source_location}"
    end
  end

  # Raised by #load_config_file when config file can not
  # be processed.
  #
  # The exception #message includes an error message formatted
  # for good display to the developer, in the console.
  #
  # Original exception raised when processing config file
  # can be found in #original. Original exception should ordinarily
  # have a good stack trace, including the file path of the config
  # file in question.
  #
  # Original config path in #config_file, and line number in config
  # file that triggered the exception in #config_file_lineno (may be nil)
  #
  # A filtered backtrace just DOWN from config file (not including trace
  # from traject loading config file itself) can be found in
  # #config_file_backtrace
  class ConfigLoadError < StandardError
    # We'd have #cause in ruby 2.1, filled out for us, but we want
    # to work before then, so we use our own 'original'
    attr_reader :original, :config_file, :config_file_lineno, :config_file_backtrace
    def initialize(config_file_path, original_exception)
      @original               = original_exception
      @config_file            = config_file_path
      @config_file_lineno     = Traject::Util.backtrace_lineno_for_config(config_file_path, original_exception)
      @config_file_backtrace  = Traject::Util.backtrace_from_config(config_file_path, original_exception)
      message = "Error loading configuration file #{self.config_file}:#{self.config_file_lineno} #{original_exception.class}:#{original_exception.message}"

      super(message)
    end
  end



end
