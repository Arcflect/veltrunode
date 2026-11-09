# frozen_string_literal: true

require_relative 'base_builder'
require_relative '../model/event_source'

module Veltrunode
  module DSL
    class EventSourceBuilder < BaseBuilder
      def initialize(type = :sqs, queue: nil, topic: nil, topic_arn: nil, bucket: nil,
                     events: nil, event: nil, filter: nil, prefix: nil, suffix: nil,
                     stream: nil, stream_arn: nil, arn: nil, starting_position: nil,
                     parallelization_factor: nil, bisect_batch_on_function_error: nil, bisect_batch: nil,
                     cluster: nil, cluster_arn: nil, msk: nil, kafka: nil,
                     broker: nil, broker_arn: nil, mq: nil, amazon_mq: nil,
                     topics: nil, queues: nil, secret: nil, secret_arn: nil, auth_secret: nil, credentials: nil,
                     auth_type: nil, authentication_type: nil, virtual_host: nil, vhost: nil,
                     consumer_group_id: nil, consumer_group: nil,
                     security_group_ids: nil, security_groups: nil, security_group: nil,
                     subnet_ids: nil, subnets: nil, subnet: nil, source_access_configurations: nil,
                     name: nil, bus: nil, event_bus: nil, event_bus_name: nil,
                     pattern: nil, event_pattern: nil, state: nil, description: nil,
                     input: nil, target: nil, target_function: nil,
                     batch_size: nil, maximum_batching_window_in_seconds: nil, report_batch_item_failures: false,
                     filter_policy: nil, filter_policy_scope: nil, enabled: true, **)
        super()
        @type = type.to_sym
        @queue = queue
        @topic = topic || topic_arn
        @bucket = bucket
        @events = events || event
        @filter = filter
        @prefix = prefix
        @suffix = suffix
        @stream = stream || stream_arn || arn
        @starting_position = starting_position
        @parallelization_factor = parallelization_factor
        @bisect_batch_on_function_error = if bisect_batch_on_function_error.nil?
                                            bisect_batch
                                          else
                                            bisect_batch_on_function_error
                                          end
        @cluster = cluster || cluster_arn || msk || kafka || arn
        @broker = broker || broker_arn || mq || amazon_mq || arn
        @topics = topics
        @queues = queues
        @secret = secret || secret_arn || auth_secret || credentials
        @auth_type = auth_type || authentication_type
        @virtual_host = virtual_host || vhost
        @consumer_group_id = consumer_group_id || consumer_group
        @security_group_ids = security_group_ids || security_groups || security_group
        @subnet_ids = subnet_ids || subnets || subnet
        @source_access_configurations = source_access_configurations
        @name = name
        @bus = bus || event_bus || event_bus_name
        @pattern = pattern || event_pattern
        @state = state
        @description = description
        @input = input
        @target_function = target || target_function
        @batch_size = batch_size
        @maximum_batching_window_in_seconds = maximum_batching_window_in_seconds
        @report_batch_item_failures = report_batch_item_failures
        @filter_policy = filter_policy
        @filter_policy_scope = filter_policy_scope
        @enabled = enabled
      end

      def queue(q)
        @queue = q
      end

      def topic(t)
        @topic = t
      end
      alias topic_arn topic

      def bucket(b)
        @bucket = b
      end

      def events(*evts)
        @events = evts.flatten
      end
      alias event events

      def filter(f = nil, **kwargs)
        @filter = if f.is_a?(Hash)
                    f.merge(kwargs)
                  elsif kwargs.empty?
                    f
                  else
                    kwargs
                  end
      end

      def prefix(p)
        @prefix = p
      end

      def suffix(s)
        @suffix = s
      end

      def stream(s)
        @stream = s
      end
      alias stream_arn stream
      alias dynamodb_stream stream
      alias kinesis_stream stream

      def starting_position(pos)
        @starting_position = pos
      end

      def parallelization_factor(factor)
        @parallelization_factor = factor
      end

      def bisect_batch_on_function_error(flag = true) # rubocop:disable Style/OptionalBooleanParameter
        @bisect_batch_on_function_error = flag
      end
      alias bisect_batch bisect_batch_on_function_error

      def cluster(c)
        @cluster = c
      end
      alias cluster_arn cluster
      alias msk cluster
      alias kafka cluster

      def broker(b)
        @broker = b
      end
      alias broker_arn broker
      alias mq broker
      alias amazon_mq broker

      def topics(*t)
        @topics = t.flatten
      end

      def queues(*q)
        @queues = q.flatten
      end

      def secret(s)
        @secret = s
      end
      alias secret_arn secret
      alias auth_secret secret
      alias credentials secret

      def auth_type(t)
        @auth_type = t
      end
      alias authentication_type auth_type

      def virtual_host(vh)
        @virtual_host = vh
      end
      alias vhost virtual_host

      def consumer_group_id(cg)
        @consumer_group_id = cg
      end
      alias consumer_group consumer_group_id

      def security_group_ids(*sgs)
        @security_group_ids = sgs.flatten
      end
      alias security_groups security_group_ids
      alias security_group security_group_ids

      def subnet_ids(*subs)
        @subnet_ids = subs.flatten
      end
      alias subnets subnet_ids
      alias subnet subnet_ids

      def source_access_configurations(cfgs)
        @source_access_configurations = cfgs
      end

      def name(n)
        @name = n
      end

      def bus(b)
        @bus = b
      end
      alias event_bus bus
      alias event_bus_name bus

      def pattern(p = nil, **kwargs)
        @pattern = if p.is_a?(Hash)
                     p.merge(kwargs)
                   elsif kwargs.empty?
                     p
                   else
                     kwargs
                   end
      end
      alias event_pattern pattern

      def state(s)
        @state = s
      end

      def description(d)
        @description = d
      end

      def input(i = nil, **kwargs)
        @input = if i.is_a?(Hash)
                   i.merge(kwargs)
                 elsif kwargs.empty?
                   i
                 else
                   kwargs
                 end
      end

      def target(t)
        @target_function = t
      end
      alias target_function target

      def batch_size(size)
        @batch_size = size
      end

      def maximum_batching_window_in_seconds(window)
        @maximum_batching_window_in_seconds = window
      end
      alias batch_window maximum_batching_window_in_seconds
      alias max_batching_window maximum_batching_window_in_seconds

      def report_batch_item_failures(enabled = true) # rubocop:disable Style/OptionalBooleanParameter
        @report_batch_item_failures = enabled
      end

      def filter_policy(policy = nil, **kwargs)
        @filter_policy = if policy.is_a?(Hash)
                           policy.merge(kwargs)
                         elsif kwargs.empty?
                           policy
                         else
                           kwargs
                         end
      end

      def filter_policy_scope(scope)
        @filter_policy_scope = scope
      end

      def enabled(flag = true) # rubocop:disable Style/OptionalBooleanParameter
        @enabled = flag
      end

      def build
        Model::EventSource.new(
          type: @type,
          queue: @queue,
          topic: @topic,
          bucket: @bucket,
          events: @events,
          filter: @filter,
          prefix: @prefix,
          suffix: @suffix,
          stream: @stream,
          starting_position: @starting_position,
          parallelization_factor: @parallelization_factor,
          bisect_batch_on_function_error: @bisect_batch_on_function_error,
          cluster: @cluster,
          broker: @broker,
          topics: @topics,
          queues: @queues,
          secret: @secret,
          auth_type: @auth_type,
          virtual_host: @virtual_host,
          consumer_group_id: @consumer_group_id,
          security_group_ids: @security_group_ids,
          subnet_ids: @subnet_ids,
          source_access_configurations: @source_access_configurations,
          name: @name,
          bus: @bus,
          pattern: @pattern,
          state: @state,
          description: @description,
          input: @input,
          target_function: @target_function,
          batch_size: @batch_size,
          maximum_batching_window_in_seconds: @maximum_batching_window_in_seconds,
          report_batch_item_failures: @report_batch_item_failures,
          filter_policy: @filter_policy,
          filter_policy_scope: @filter_policy_scope,
          enabled: @enabled
        )
      end
    end
  end
end
