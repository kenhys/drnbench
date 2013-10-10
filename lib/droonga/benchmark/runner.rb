# -*- coding: utf-8 -*-

require "thread"
require "net/http"
require "json"

module Droonga
  module Benchmark
    class Runner
      attr_reader :duration, :n_clients, :result

      MIN_DURATION = 1
      DEFAULT_DURATION = 10
      MIN_WAIT = 0
      DEFAULT_WAIT = 1
      MAX_N_CLIENTS = 16
      DEFAULT_N_CLIENTS = 1
      TOTAL_N_REQUESTS = 1000

      DEFAULT_HOST = "localhost"
      DEFAULT_PORT = 80

      def initialize(params)
        @duration = [params[:duration] || DEFAULT_DURATION, MIN_DURATION].max
        @n_clients = [params[:n_clients] || DEFAULT_N_CLIENTS, MAX_N_CLIENTS].min
        @n_requests = params[:n_requests] || TOTAL_N_REQUESTS

        params[:host] ||= DEFAULT_HOST
        params[:port] ||= DEFAULT_PORT
        params[:wait] ||= DEFAULT_WAIT
        params[:wait] = [params[:wait], MIN_WAIT].max

        @params = params

        if params[:request_pattern]
          params[:request_pattern][:frequency] = 1
          @request_patterns = [params[:request_pattern]]
        else
          @request_patterns = params[:request_patterns]
        end
        populate_requests
      end

      def run
        process_requests
        @result
      end

      private
      def process_requests
        requests_queue = Queue.new
        @result = Result.new(:n_clients => @n_clients,
                             :duration => @duration)

        @clients = @n_clients.times.collect do |index|
          client = HttpClient.new(@params.merge(:requests => requests_queue,
                                                :result => @result))
          client.run
          client
        end

        start_time = Time.now
        while Time.now - start_time < @duration
          if requests_queue.empty?
            @requests.each do |request|
              requests_queue.push(request)
            end
          end
          sleep 1
        end

        @clients.each do |client|
          client.stop
        end

        @result
      end

      def populate_requests
        @requests = []

        if @request_patterns.is_a?(Array)
          @request_patterns.each do |request_pattern|
            populate_request_pattern(request_pattern)
          end
        else
          @request_patterns.each do |key, request_pattern|
            populate_request_pattern(request_pattern)
          end
        end

        @requests.shuffle!
      end

      def populate_request_pattern(request_pattern)
        frequency = request_pattern[:frequency].to_f
        n_requests = @n_requests * frequency

        base_patterns = nil
        if request_pattern[:pattern]
          base_patterns = [request_pattern[:pattern]]
        else
          base_patterns = request_pattern[:patterns]
        end
        base_patterns = base_patterns.shuffle

        n_requests.round.times do |count|
          @requests << base_patterns[count % base_patterns.size]
        end
      end

      class HttpClient
        attr_reader :requests, :results, :wait

        DEFAULT_PATH = "/"
        DEFAULT_METHOD = "GET"

        def initialize(params)
          @requests = params[:requests]
          @result = params[:result]
          @wait = params[:wait]

          @default_host = params[:host]
          @default_port = params[:port]
          @default_path = params[:path] || DEFAULT_PATH
          @default_method = params[:method] || DEFAULT_METHOD
        end

        def run
          @thread = Thread.new do
            loop do
              request = @requests.pop
              request[:host] ||= @default_host
              request[:port] ||= @default_port
              request[:path] ||= @default_path
              request[:method] ||= @default_method
              request[:method] = request[:method].upcase

              Net::HTTP.start(request[:host], request[:port]) do |http|
                header = {
                  "user-agent" => "Ruby/#{RUBY_VERSION} Droonga::Benchmark::Runner::HttpClient"
                }
                response = nil
                start_time = Time.now
                case request[:method]
                when "GET"
                  response = http.get(request[:path], header)
                when "POST"
                  body = request[:body]
                  unless body.is_a?(String)
                    body = JSON.generate(body)
                  end
                  response = http.post(request[:path], body, header)
                end
                @result << {
                  :request => request,
                  :status => response.code,
                  :elapsed_time => Time.now - start_time,
                }
              end
              sleep @wait
            end
          end
          self
        end

        def stop
          @thread.exit
        end
      end

      class Result
        attr_reader :n_clients, :duration, :statuses

        class << self
          def keys
            [
              :n_clients,
              :total_n_requests,
              :queries_per_second,
              :min_elapsed_time,
              :max_elapsed_time,
              :average_elapsed_time,
            ]
          end
        end

        def initialize(params)
          @n_clients = params[:n_clients]
          @duration = params[:duration]

          @results = []
          @total_elapsed_time = 0.0
          @elapsed_times = []
          @statuses = {}
        end

        def <<(result)
          clear_cached_statistics

          @results << result

          @statuses[result[:status]] ||= 0
          @statuses[result[:status]] += 1

          @elapsed_times << result[:elapsed_time]
          @total_elapsed_time += result[:elapsed_time]
        end

        def total_n_requests
          @total_n_requests ||= @results.size
        end

        def queries_per_second
          @queries_per_second ||= total_n_requests.to_f / @duration
        end

        def status_percentages
          @status_percentages ||= prepare_status_percentages
        end

        def min_elapsed_time
          @min_elapsed_time ||= @elapsed_times.min
        end

        def max_elapsed_time
          @max_elapsed_time ||= @elapsed_times.min
        end

        def average_elapsed_time
          @average_elapsed_time ||= @total_elapsed_time / @elapsed_times.size
        end

        def to_s
          "Total requests: #{total_n_requests} " +
            "(#{queries_per_second} queries per second)\n" +
          "Status:\n" +
          status_percentages.collect do |status, percentage|
            "  #{status}: #{percentage} %"
          end.join("\n") + "\n" +
          "Elapsed time:\n" +
          "  min:     #{min_elapsed_time} sec\n" +
          "  max:     #{max_elapsed_time} sec\n" +
          "  average: #{average_elapsed_time} sec"
        end

        def values
          self.class.keys.collect do |column|
            send(column)
          end
        end

        private
        def clear_cached_statistics
          @total_n_requests = nil
          @queries_per_second = nil
          @status_percentages = nil
          @min_elapsed_time = nil
          @max_elapsed_time = nil
          @average_elapsed_time = nil
        end

        def prepare_status_percentages
          status_percentages = []
          @statuses.each do |status, n_results|
            percentage = n_results.to_f / total_n_requests * 100
            status_percentages << {:percentage => percentage,
                                   :status => status}
          end
          status_percentages.sort! do |a, b|
            (-1) * (a[:percentage] <=> b[:percentage])
          end
          status_percentages = {}
          status_percentages.each do |status|
            status_percentages[status[:status]] = status[:percentage]
          end
          status_percentages
        end
      end
    end
  end
end
