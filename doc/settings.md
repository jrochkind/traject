# Traject settings

Traject settings are a flat list of key/value pairs -- a single
Hash, not nested. Keys are always strings, and dots (".") can be
used for grouping and namespacing.

Values are usually strings, but occasionally something else.

Settings can be set in configuration files, usually like:

~~~ruby
settings do
  provide "key", "value"
end
~~~~

or on the command line: `-s key=value`.  There are also some command line shortcuts
for commonly used settings, see `traject -h`. 

## Known settings

* `debug_ascii_progress`: true/'true' to print ascii characters to STDERR indicating progress. Note,
                          yes, this is fixed to STDERR, regardless of your logging setup. 
                          * `.` for every batch of records read and parsed
                          * `^` for every batch of records batched and queued for adding to solr
                                (possibly in thread pool)
                          * `%` for completing of a Solr 'add'
                          * `!` when threadpool for solr add has a full queue, so solr add is
                                going to happen in calling queue -- means solr adding can't
                                keep up with production. 

* `json_writer.pretty_print`: used by the JsonWriter, if set to true, will output pretty printed json (with added whitespace) for easier human readability. Default false.

* `log.file`: filename to send logging, or 'STDOUT' or 'STDERR' for those streams. Default STDERR

* `log.error_file`: Default nil, if set then all log lines of ERROR and higher will be _additionally_
                  sent to error file named.

* `log.format`: Formatting string used by Yell logger. https://github.com/rudionrails/yell/wiki/101-formatting-log-messages

* `log.level`:  Log this level and above. Default 'info', set to eg 'debug' to get potentially more logging info,
              or 'error' to get less. https://github.com/rudionrails/yell/wiki/101-setting-the-log-level

* `log.batch_progress`: If set to a number N (or string representation), will output a progress line to INFO
   log, every N records. 

* `marc_source.type`: default 'binary'. Can also set to 'xml' or (not yet implemented todo) 'json'. Command line shortcut `-t`

* `marc4j_reader.jar_dir`:   Path to a directory containing Marc4J jar file to use. All .jar's in dir will
                           be loaded. If unset, uses marc4j.jar bundled with traject.

* `marc4j_reader.permissive`: Used by Marc4JReader only when marc.source_type is 'binary', boolean, argument to the underlying MarcPermissiveStreamReader. Default true.

* `marc4j_reader.source_encoding`: Used by Marc4JReader only when marc.source_type is 'binary', encoding strings accepted
  by marc4j MarcPermissiveStreamReader. Default "BESTGUESS", also "UTF-8", "MARC"

* `output_file`: Output file to write to for operations that write to files: For instance the `marcout` command,
                 or Writer classes that write to files, like Traject::JsonWriter. Has an shortcut
                 `-o` on command line. 

* `processing_thread_pool` Default 3. Main thread pool used for processing records with input rules. Choose a
   pool size based on size of your machine, and complexity of your indexing rules. 
   Probably no reason for it ever to be more than number of cores on indexing machine.  
   But this is the first thread_pool to try increasing for better performance on a multi-core machine. 
   
   A pool here can sometimes result in multi-threaded commiting to Solr too with the
   SolrJWriter, as processing worker threads will do their own commits to solr if the
   solrj_writer.thread_pool is full. Having a multi-threaded pool here can help even out throughput
   through Solr's pauses for committing too. 

* `reader_class_name`: a Traject Reader class, used by the indexer as a source of records. Default Traject::Marc4jReader. If you don't need to read marc binary with Marc8 encoding, the pure ruby MarcReader may give you better performance.  Command-line shortcut `-r`

* `solr.url`: URL to connect to a solr instance for indexing, eg http://example.org:8983/solr . Command-line short-cut `-u`.

* `solrj.jar_dir`: SolrJWriter needs to load Java .jar files with SolrJ. It will load from a packaged SolrJ, but you can load your own SolrJ (different version etc) by specifying a directory. All *.jar in directory will be loaded.

* `solr.version`: Set to eg "1.4.0", "4.3.0"; currently un-used, but in the future will control
  change some default settings, and/or sanity check and warn you if you're doing something
  that might not work with that version of solr. Set now for help in the future.

* `solrj_writer.batch_size`: size of batches that SolrJWriter will send docs to Solr in. Default 200. Set to nil,
  0, or 1, and SolrJWriter will do one http transaction per document, no batching. 

* `solrj_writer.commit_on_close`: default false, set to true to have SolrJWriter send an explicit commit message to Solr after indexing.

* `solrj_writer.parser_class_name`: Set to "XMLResponseParser" or "BinaryResponseParser". Will be instantiated and passed to the solrj.SolrServer with setResponseParser. Default nil, use SolrServer default. To talk to a solr 1.x, you will want to set to "XMLResponseParser"

* `solrj_writer.server_class_name`: String name of a solrj.SolrServer subclass to be used by SolrJWriter. Default "HttpSolrServer"

* `solrj_writer.thread_pool`:       Defaults to 1 (single bg thread). A thread pool is used for submitting docs
                                    to solr. Set to 0 or nil to disable threading. Set to 1,
                                    there will still be a single bg thread doing the adds.
                                    May make sense to set higher than number of cores on your
                                    indexing machine, as these threads will mostly be waiting
                                    on Solr. Speed/capacity of your solr might be more relevant.
                                    Note that processing_thread_pool threads can end up submitting
                                    to solr too, if solrj_writer.thread_pool is full. 

* `writer_class_name`: a Traject Writer class, used by indexer to send processed dictionaries off. Default Traject::SolrJWriter, also available Traject::JsonWriter. See Traject::Indexer for more info. Command line shortcut `-w`