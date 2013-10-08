# -*- coding: utf-8 -*-

require "thread"
require "net/http"
require "json"
require "droonga/http-benchmark/formatter"

module Droonga
  module HttpBenchmark
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
      DEFAULT_PATH = "/"
      DEFAULT_METHOD = "GET"

      def initialize(params)
        @duration = [params[:duration] || DEFAULT_DURATION, MIN_DURATION].max
        @wait = [params[:wait] || DEFAULT_WAIT, MIN_WAIT].max
        @n_clients = [params[:n_clients] || DEFAULT_N_CLIENTS, MAX_N_CLIENTS].min
        @n_requests = params[:n_requests] || TOTAL_N_REQUESTS

        @default_host = params[:host] || DEFAULT_HOST
        @default_port = params[:port] || DEFAULT_PORT
        @default_path = params[:path] || DEFAULT_PATH
        @default_method = params[:method] || DEFAULT_METHOD

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
        analyze_results
        Formatter.output_one_result(@result)
        @result
      end

      private
      def process_requests
        requests_queue = Queue.new
        results_queue = Queue.new

        @clients = @n_clients.times.collect do |index|
          client = Client.new(:requests => requests_queue,
                              :results => results_queue,
                              :wait => @wait)
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

        @results = []
        while not results_queue.empty?
          @results << results_queue.pop
        end
      end

      def analyze_results
        total_n_requests = @results.size
        http_statuses = {}
        min_elapsed_time = @duration
        max_elapsed_time = 0
        total_elapsed_time = 0

        @results.each do |result|
          http_statuses[result[:status]] ||= 0
          http_statuses[result[:status]] += 1

          if result[:elapsed_time] < min_elapsed_time
            min_elapsed_time = result[:elapsed_time]
          end
          if result[:elapsed_time] > max_elapsed_time
            max_elapsed_time = result[:elapsed_time]
          end
          total_elapsed_time += result[:elapsed_time]
        end

        http_status_percentages = []
        http_statuses.each do |status, n_results|
          percentage = n_results.to_f / total_n_requests * 100
          http_status_percentages << { :percentage => percentage,
                                       :status => status }
        end
        http_status_percentages.sort! do |a, b|
          (-1) * (a[:percentage] <=> b[:percentage])
        end
        sorted_http_statuses = {}
        http_status_percentages.each do |status|
          sorted_http_statuses[status[:status]] = status[:percentage]
        end

        @result = {
          :total_n_requests => total_n_requests,
          :queries_per_second => total_n_requests.to_f / @duration,
          :responses => sorted_http_statuses,
          :min_elapsed_time => min_elapsed_time,
          :max_elapsed_time => max_elapsed_time,
          :average_elapsed_time => total_elapsed_time / total_n_requests,
        }
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
          request = base_patterns[count % base_patterns.size]
          request[:host] ||= @default_host
          request[:port] ||= @default_port
          request[:path] ||= @default_path
          request[:method] ||= @default_method
          request[:method] = request[:method].upcase
          @requests << request
        end
      end

      class Client
        attr_reader :requests, :results, :wait

        def initialize(params)
          @requests = params[:requests]
          @results = params[:results]
          @wait = params[:wait]
        end

        def run
          @thread = Thread.new do
            loop do
              request = @requests.pop
              Net::HTTP.start(request[:host], request[:port]) do |http|
                header = {
                  "user-agent" => "Ruby/#{RUBY_VERSION} Droonga::HttpBenchmark::Runner::Client"
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
                @results.push(:request => request,
                              :status => response.code,
                              :elapsed_time => Time.now - start_time)
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
    end
  end
end
