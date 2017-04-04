module Sneakers
  module Metrics
    class NewrelicMetrics

      def self.eagent(eagent = nil)
        @eagent = eagent || @eagent
      end

      def initialize()
        #@connection = conn
      end

      def increment(metric)
        metric.gsub! "\.", "\/"
        NewrelicMetrics.eagent::Agent.increment_metric("Custom/#{metric}", 1)
      rescue Exception => e
        puts "NewrelicMetrics#increment: #{e}"
      end

      def timing(metric, &block)
        metric.gsub! "\.", "\/"
        start = Time.now
        block.call
        NewrelicMetrics.eagent::Agent.record_metric("Custom/#{metric}", ((Time.now - start) * 1000).floor)
      rescue Exception => e
        puts "NewrelicMetrics#timing: #{e}"
      end

    end
  end
end

