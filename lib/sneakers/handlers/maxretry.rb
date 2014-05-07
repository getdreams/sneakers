module Sneakers
  module Handlers
    #
    # Maxretry uses dead letter policies on Rabbitmq to requeue and retry
    # messages after failure (rejections, errors and timeouts). When the maximum
    # number of retries is reached it will put the message on an error queue.
    # This handler will only retry at the queue level. To accomplish that, the
    # setup is a bit complex.
    #
    # Input:
    #   worker_exchange (eXchange)
    #   worker_queue (Queue)
    # We create:
    #   worker_queue-retry - (X) where we setup the worker queue to dead-letter.
    #   worker_queue-retry - (Q) queue bound to ^ exchange, dead-letters to
    #                        worker_queue-retry-requeue.
    #   worker_queue-error - (X) where to send max-retry failures
    #   worker_queue-error - (Q) bound to worker_queue-error.
    #   worker_queue-retry-requeue - (X) exchange to bind worker_queue to for
    #                                requeuing directly to the worker_queue.
    #
    # This requires that you setup arguments to the worker queue to line up the
    # dead letter queue. See the example for more information.
    #
    # Many of these can be override with options:
    # - retry_exchange - sets retry exchange & queue
    # - retry_error_exchange - sets error exchange and queue
    # - retry_requeue_exchange - sets the exchange created to re-queue things
    #   back to the worker queue.
    #
    class Maxretry

      def initialize(channel, queue, opts)
        @worker_queue_name = queue.name
        Sneakers.logger.debug do
          "Creating a Maxretry handler for queue(#{@worker_queue_name}),"\
          " opts(#{opts})"
        end

        @channel = channel
        @opts = opts

        # Construct names, defaulting where suitable
        retry_name = @opts[:retry_exchange] || "#{@worker_queue_name}-retry"
        error_name = @opts[:retry_error_exchange] || "#{@worker_queue_name}-error"
        requeue_name = @opts[:retry_requeue_exchange] || "#{@worker_queue_name}-retry-requeue"

        # Create the exchanges
        @retry_exchange, @error_exchange, @requeue_exchange = [retry_name, error_name, requeue_name].map do |name|
          Sneakers.logger.debug { "Creating exchange #{name} for retry handler on worker queue #{@worker_queue_name}" }
          @channel.exchange(name,
                            :type => 'topic',
                            :durable => opts[:durable])
        end

        # Create the queues and bindings
        Sneakers.logger.debug do
          "Creating queue #{retry_name}, dead lettering to #{requeue_name}"
        end
        @retry_queue = @channel.queue(retry_name,
                                     :durable => opts[:durable],
                                     :arguments => {
                                       :'x-dead-letter-exchange' => requeue_name,
                                       :'x-message-ttl' => @opts[:retry_timeout] || 60000
                                     })
        @retry_queue.bind(@retry_exchange, :routing_key => '#')

        Sneakers.logger.debug do
          "Creating queue #{error_name}"
        end
        @error_queue = @channel.queue(error_name,
                                      :durable => opts[:durable])
        @error_queue.bind(@error_exchange, :routing_key => '#')

        # Finally, bind the worker queue to our requeue exchange
        queue.bind(@requeue_exchange, :routing_key => '#')

        @max_retries = @opts[:retry_max_times] || 5

      end

      def acknowledge(hdr, props, msg)
        @channel.acknowledge(hdr.delivery_tag, false)
      end

      def reject(hdr, props, msg, requeue=false)

        # Note to readers, the count of the x-death will increment by 2 for each
        # retry, once for the reject and once for the expiration from the retry
        # queue
        if requeue || ((failure_count(props[:headers]) + 1) <= @max_retries)
          # We call reject which will route the message to the
          # x-dead-letter-exchange (ie. retry exchange)on the queue
          Sneakers.logger.debug do
            "Retrying failure, count #{failure_count(props[:headers]) + 1}, headers #{props[:headers]}"
          end unless requeue # This is only relevant if we're in the failure path.
          @channel.reject(hdr.delivery_tag, requeue)
          # TODO: metrics
        else
          # Retried more than the max times
          # Publish the original message with the routing_key to the error exchange
          @error_exchange.publish(msg, :routing_key => hdr.routing_key)
          @channel.acknowledge(hdr.delivery_tag, false)
          # TODO: metrics
        end
      end

      def error(hdr, props, msg, err)
        reject(hdr, props, msg)
      end

      def timeout(hdr, props, msg)
        reject(hdr, props, msg)
      end

      def noop(hdr, props, msg)

      end

      # Uses the x-death header to determine the number of failures this job has
      # seen in the past. This does not count the current failure. So for
      # instance, the first time the job fails, this will return 0, the second
      # time, 1, etc.
      # @param headers [Hash] Hash of headers that Rabbit delivers as part of
      #   the message
      # @return [Integer] Count of number of failures.
      def failure_count(headers)
        if headers.nil? || headers['x-death'].nil?
          0
        else
          headers['x-death'].select do |x_death|
            x_death['queue'] == @worker_queue_name
          end.count
        end
      end
      private :failure_count
    end
  end
end
