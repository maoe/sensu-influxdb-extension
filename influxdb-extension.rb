#!/usr/bin/env ruby
# coding: utf-8

require "net/http"
require "json"

module Sensu::Extension
  class InfluxDB < Handler

    @@extension_name = "influxdb-extension"

    def name
      @@extension_name
    end

    def description
      "Transforms and sends metrics to InfluxDB"
    end

    def post_init
      influxdb_config = settings[@@extension_name] || Hash.new
      validate_config(influxdb_config)

      hostname         = influxdb_config[:hostname] || "127.0.0.1"
      port             = influxdb_config[:port] || "8086"
      database         = influxdb_config[:database]
      ssl              = influxdb_config[:ssl] || false
      ssl_ca_file      = influxdb_config[:ssl_ca_file]
      ssl_verify       = if influxdb_config.key?(:ssl_verify) then influxdb_config[:ssl_verify] else true end
      precision        = influxdb_config[:precision] || "s"
      retention_policy = influxdb_config[:retention_policy]
      rp_queryparam    = if retention_policy.nil? then "" else "&rp=#{retention_policy}" end
      protocol         = if ssl then "https" else "http" end
      username         = influxdb_config[:username]
      password         = influxdb_config[:password]
      auth_queryparam  = if username.nil? or password.nil? then "" else "&u=#{username}&p=#{password}" end
      @BUFFER_SIZE     = if influxdb_config.key?(:buffer_size) then influxdb_config[:buffer_size].to_i else 100 end
      @BUFFER_MAX_AGE  = if influxdb_config.key?(:buffer_max_age) then influxdb_config[:buffer_max_age].to_i else 10 end
      @PROXY_MODE      = influxdb_config[:proxy_mode] || false

      string = "#{protocol}://#{hostname}:#{port}/write?db=#{database}&precision=#{precision}#{rp_queryparam}#{auth_queryparam}"
      @uri = URI(string)
      @http = Net::HTTP::new(@uri.host, @uri.port)
      if ssl
        @http.ssl_version = :TLSv1
        @http.use_ssl = true
        @http.verify_mode = if ssl_verify then OpenSSL::SSL::VERIFY_PEER else OpenSSL::SSL::VERIFY_NONE end
        @http.ca_file = ssl_ca_file
      end
      @buffer = []
      @buffer_flushed = Time.now.to_i

      @logger.info("#{@@extension_name}: successfully initialized config: hostname: #{hostname}, port: #{port}, database: #{database}, uri: #{@uri.to_s}, username: #{username}, buffer_size: #{@BUFFER_SIZE}, buffer_max_age: #{@BUFFER_MAX_AGE}")
    end

    def run(event)
      begin

        if buffer_too_old? or buffer_too_big?
          flush_buffer
        end

        event = JSON.parse(event)
        output = event["check"]["output"]

        if not @PROXY_MODE
          client_tags = event["client"]["tags"] || Hash.new
          check_tags = event["check"]["tags"] || Hash.new
          tags = create_tags(client_tags.merge(check_tags))
        end

        output.split(/\r\n|\n/).each do |point|
            if not @PROXY_MODE
              measurement, field_value, timestamp = point.split(/\s+/)

              if not is_number?(timestamp)
                @logger.debug("invalid timestamp, skipping line in event #{event}")
                next
              end

              # Get event output tags
              if measurement.include?('eventtags')
                only_measurement, tagstub = measurement.split('.eventtags.',2)
                event_tags = Hash.new()
                tagstub.split('.').each_slice(2) do |key, value|
                  event_tags[key] = value
                end
                measurement = only_measurement
                tags = create_tags(client_tags.merge(check_tags).merge(event_tags))
              end

              point = "#{measurement}#{tags} value=#{field_value} #{timestamp}"
            end

            @buffer.push(point)
            @logger.debug("#{@@extension_name}: stored point in buffer (#{@buffer.length}/#{@BUFFER_SIZE})")
        end
      rescue => e
        @logger.debug("#{@@extension_name}: unable to post payload to influxdb for event #{event} - #{e.backtrace.to_s}")
      end
      yield('', 0)
    end

    def create_tags(tags)
        begin
            # sorting tags alphabetically in order to increase influxdb performance
            sorted_tags = Hash[tags.sort]

            tag_string = ""

            sorted_tags.each do |tag, value|
                next if value.to_s.empty? # skips tags without values
                tag_string += ",#{tag}=#{value}"
            end

            @logger.debug("#{@@extension_name}: created tags: #{tag_string}")
            tag_string
        rescue => e
            @logger.debug("#{@@extension_name}: unable to create tag string from #{tags} - #{e.backtrace.to_s}")
            ""
        end
    end

    def send_to_influxdb(payload)
        request = Net::HTTP::Post.new(@uri.request_uri)
        request.body = payload

        @logger.debug("#{@@extension_name}: writing payload #{payload} to endpoint #{@uri.to_s}")
        begin
          response = @http.request(request)
          @logger.debug("#{@@extension_name}: influxdb http response code = #{response.code}, body = #{response.body}")
        rescue => e
          @logger.error("unable to send payload to InfluxDB #{e}")
          ""
        end
    end

    def flush_buffer
      payload = @buffer.join("\n")
      send_to_influxdb(payload)
      @buffer = []
      @buffer_flushed = Time.now.to_i
    end

    def buffer_too_old?
      buffer_age = Time.now.to_i - @buffer_flushed
      buffer_age >= @BUFFER_MAX_AGE
    end

    def buffer_too_big?
      @buffer.length >= @BUFFER_SIZE
    end

    def validate_config(config)
      if config.nil?
        raise ArgumentError, "no configuration for #{@@extension_name} provided. exiting..."
      end

      ["hostname", "database"].each do |required_setting|
        if config[required_setting].nil?
          raise ArgumentError, "required setting #{required_setting} not provided to extension. this should be provided as json element with key #{@@extension_name}. exiting..."
        end
      end
    end

    def is_number?(input)
      true if Integer(input) rescue false
    end
  end
end
