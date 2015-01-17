require 'concurrent'
require 'thread' # for Queue

module Traject
  # An abstraction wrapping a Concurrent::ThreadPool in some configuration choices
  # and other apparatus.  Concurrent::ThreadPool is a Java ThreadPool executor on
  # jruby for performance, and is ruby-concurrent's own ruby implementation otherwise.
  #
  # 1) Initialize with chosen pool size -- we create fixed size pools, where
  # core and max sizes are the same.
  #
  # 2) If initialized with nil for threadcount,  no thread pool will actually
  # be created, and all threadpool-related methods become no-ops. We call this
  # the nil/null threadpool.  A non-nil threadpool requires jruby, but you can
  # create a null Traject::ThreadPool.new(nil) under MRI without anything
  # complaining.
  #
  # 3) Use the #maybe_in_threadpool method to send blocks to thread pool for
  # execution -- if no threadpool configured your block will just be
  # executed in calling thread. Be careful to not refer to any non-local
  # variables in the block, unless the variable has an object you can
  # use thread-safely!
  #
  # 4) Thread pools Concurrent::ThreadPoolExecutor,
  # with a work queue that will buffer up to (pool_size*3) tasks. If queue is full,
  # the ThreadPoolExecutor is set up to use the :caller_runs policy
  # meaning the block will end up executing in caller's own thread. With the kind
  # of work we're doing, where each unit of work is small and there are many of them--
  # the :caller_runs serves as an effective 'back pressure' mechanism to keep
  # the work queue from getting too large and exhausting memory, when producers are
  # faster than consumers.
  #
  # 5) Any exceptions raised by pool-executed work are captured accumulated in a thread-safe
  #  manner, and can be re-raised in the thread of your choice by calling
  #  #raise_collected_exception!
  #
  # 6) When you are done with the threadpool, you can and must call
  #  #shutdown_and_wait, which will wait for all current queued work
  #  to complete, then return.  You can not give any more work to the pool
  #  after you do this. By default it'll wait pretty much forever, which should
  #  be fine. If you never call shutdown, the pool will keep running forever
  #  and not allow your program to exit!
  #
  # 7) We will keep track of total times a block is run in thread pool, and
  #  total elapsed (wall) time of running all blocks, so an average_execution_ms
  #  time can be given.  #average_execution_ms may be inaccurate if called when
  #  threads are still executing, as it's not entirely thread safe (may get
  #  an off by one as to total iterations)
  class ThreadPool
    attr_reader :pool_size, :queue_capacity

    # First arg is pool size, 0 or nil and we'll be a null/no-op pool which executes
    # work in caller thread. 
    def initialize(pool_size)
      unless pool_size.nil? || pool_size == 0
        @pool_size = pool_size.to_i 
        @queue_capacity = pool_size * 3

        @thread_pool = Concurrent::ThreadPoolExecutor.new(
          :min_threads     => @pool_size,
          :max_threads     => @pool_size,
          :max_queue       => @queue_capacity,
          :overflow_policy => :caller_runs
        )

        # A thread-safe queue to collect exceptions cross-threads.
        # We really only need to save the first exception, but a queue
        # is a convenient way to store a value concurrency-safely, and
        # might as well store all of them. 
        @exceptions_caught_queue   =  Queue.new
      end
    end

    # Pass it a block, MAYBE gets executed in the bg in a thread pool. Maybe
    # gets executed in the calling thread.
    #
    # There are actually two 'maybes':
    #
    # * If Traject::ThreadPool was configured with null thread pool, then ALL
    #   work will be executed in calling thread.
    #
    # * If there is a thread pool, but it's work queue is full, then a job
    #   will be executed in calling thread (because we configured our java
    #   thread pool with a limited sized queue, and CallerRunsPolicy rejection strategy)
    #
    # You can pass arbitrary arguments to the method, that will then be passed
    # to your block -- similar to how ruby Thread.new works. This is convenient
    # for creating variables unique to the block that won't be shared outside
    # the thread:
    #
    #     thread_pool.maybe_in_thread_pool(x, y) do |x1, y1|
    #       100.times do
    #         something_with(x1)
    #       end
    #     end
    #     x = "someting else"
    #     # If we hadn't passed args with block, and had just
    #     # used x in the block, it'd be the SAME x as this one,
    #     # and would be pointing to a different string now!
    #
    #  Note, that just makes block-local variables, it doesn't
    #  help you with whether a data structure itself is thread safe.
    def maybe_in_thread_pool(*args)
      start_t = Time.now

      if @thread_pool
        @thread_pool.post do
          begin
            yield(*args)
          rescue Exception => e
            collect_exception(e)
          end
        end
      else
        yield(*args)
      end

    end


    # thread-safe way of storing an exception, to raise
    # later in a different thread. We don't guarantee
    # that we can store more than one at a time, only
    # the first one recorded may be stored.
    def collect_exception(e)
      @exceptions_caught_queue.push(e)
    end

    # If there's a stored collected exception, raise it
    # again now. Call this to re-raise exceptions caught in
    # other threads in the thread of your choice.
    #
    # If you call this method on a ThreadPool initialized with nil
    # as a non-functioning threadpool -- then this method is just
    # a no-op.
    def raise_collected_exception!
      if @exceptions_caught_queue && (! @exceptions_caught_queue.empty?)
        e = @exceptions_caught_queue.pop
        raise e
      end
    end

    # shutdown threadpool, and wait for all work to complete.
    # this one is also a no-op if you have a null ThreadPool that
    # doesn't really have a threadpool at all.
    #
    # returns elapsed time in seconds it took to shutdown
    def shutdown_and_wait
      start_t = Time.now

      if @thread_pool
        @thread_pool.shutdown
        @thread_pool.wait_for_termination
      end

      return (Time.now - start_t)
    end

  end
end
