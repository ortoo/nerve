require 'logger'
require 'json'
require 'timeout'
require 'digest/sha1'
require 'set'

require 'em/pure_ruby'
require 'eventmachine'

require 'nerve/version'
require 'nerve/utils'
require 'nerve/log'
require 'nerve/ring_buffer'
require 'nerve/reporter'
require 'nerve/service_watcher'

module Nerve
  class NerveServer < EM::Connection
    include Logging
    @@connected_clients = Array.new
    def initialize(nerve)
      @nerve = nerve
      @services = Set.new
    end
    def unbind
      @@connected_clients.delete(self)
      log.info "TCP client disconnected"
      @services.each do |key|
        @nerve.remove_watcher key
      end
    end
    def receive_data(data)
      # Attempt to parse as JSON
      begin
        json = JSON.parse(data)
        @services.merge(@nerve.receive(json))
      rescue JSON::ParserError => e
        # nope!
      rescue => e
        $stdout.puts $!.inspect, $@
        $stderr.puts $!.inspect, $@
      end
    end
  end

  class Nerve
    include Logging

    def initialize(opts={})
      # trap int signal and set exit to true
      %w{INT TERM}.each do |signal|
        trap(signal) do
          puts "Caught signal"
          EventMachine.stop
        end
      end

      log.info 'nerve: starting up!'

      # required options
      log.debug 'nerve: checking for required inputs'
      %w{instance_id services}.each do |required|
        raise ArgumentError, "you need to specify required argument #{required}" unless opts[required]
      end

      @instance_id = opts['instance_id']

      # create service watcher objects
      log.debug 'nerve: creating service watchers'
      @service_watchers={}
      opts['services'].each do |name, config|
        @service_watchers[name] = ServiceWatcher.new(config.merge({'instance_id' => @instance_id, 'name' => name}))
      end

      @ephemeral_service_watchers={}

      @port = opts['listen_port'] || 1025
      @port = @port.to_i

      @expiry = opts['ephemeral_service_expiry'] || 60
      @expiry = @expiry.to_i

      log.debug 'nerve: completed init'
    end

    def run
      log.info 'nerve: starting run'
      begin
        log.debug 'nerve: initializing service checks'
        @service_watchers.each do |name,watcher|
          watcher.init
        end

        log.debug 'nerve: main initialization done'

        EventMachine.run do
          EM.add_periodic_timer(1) {
            @service_watchers.each do |name,watcher|
              if watcher.expires and Time.now.to_i > watcher.expires_at
                next
              end
              watcher.run
            end
          }
          log.info "nerve: listening on port #{@port} for services"
          EventMachine.start_server("127.0.0.1", @port, NerveServer, self)
        end

        @service_watchers.each do |name,watcher|
          watcher.close!
        end
      rescue => e
        $stdout.puts $!.inspect, $@
        $stderr.puts $!.inspect, $@
      ensure
        EventMachine.stop
      end
      log.info 'nerve: exiting'
    end

    def remove_watcher(key)
      if @service_watchers.has_key? key
      log.info "removing service watcher for #{key} because it has expired"
      @service_watchers[key].close!
      @service_watchers.delete key
      else
        log.warn "can't remove service watcher for #{key} because it's not present"
      end
    end
    def receive(json)
      return nil unless json.has_key? 'services'
      services = Set.new
      json['services'].each do |name,params|
        sha1 = Digest::SHA1.hexdigest params.to_s
        params = params.merge({'instance_id' => @instance_id, 'name' => name, 'sha1' => sha1})
        port = params['port']
        key = "#{name}_#{params['port']}"
        if @service_watchers.has_key? key
          if @service_watchers[key].sha1 != sha1
            remove_watcher(key)
          else
            @service_watchers[key].expires_at = Time.now.to_i + @expiry
          end
        end

        if not @service_watchers.has_key? key
          begin
            log.info "adding new ephemeral service watcher for #{key}"
            s = ServiceWatcher.new(params)
            s.expires = true
            s.init
            @service_watchers[key] = s
          rescue ArgumentError => e
            log.info e
          end
        end
        services.add(key)
      end
      services.to_a
    end
  end
end
