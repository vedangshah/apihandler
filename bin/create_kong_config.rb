#!/usr/bin/env ruby
#
#
# This executable file is responsible for creating kong configuration
# from a provided config file.
#
# refer to the provided kong_config.yaml

require 'yaml'
require 'curb'
require 'octocore'
require 'json'
require 'securerandom'
require 'digest/sha1'

module Octo

  module GeneratorHelpers

    def generate_api_key
      SecureRandom.hex
    end

    def generate_password(salt = nil)
      Digest::SHA1.hexdigest([SecureRandom.base64, salt].join())
    end
  end

  module EnterpriseGenetaor

    include Octo::GeneratorHelpers

    def create_enterprise(enterprise)
      puts "Attempting to create new enterprise with name: #{ enterprise[:name]}"
      unless enterprise_name_exists?(enterprise[:name])

        # create enterprise
        e = Octo::Enterprise.new
        e.name = enterprise[:name]
        e.save!

        # create its Authentication stuff
        auth = Octo::Authorization.new
        auth.enterprise = e
        auth.username = e.name
        auth.apikey = generate_api_key
        auth.email = enterprise[:email]
        auth.password = generate_password
        auth.save!

        method = :put
        url = '/consumers/'
        payload = {username: e.name, custom_id: e.id.to_s}
        make_kong_request method, url, payload

        create_key_auth_config(e.name, auth.apikey)
      else
        puts 'Not creating client as client name exists'
      end
    end


    def create_api(api)
      url = '/apis'
      method = :put
      payload = {
          strip_request_path: true,
          preserve_host: false
      }
      payload.merge!api
      puts make_kong_request method, url, payload
    end

    def create_plugin(api_name, plugin, config = {})
      puts "Adding Plugin #{ plugin } for api #{ api_name }"
      method = :put
      url = "/apis/#{ api_name}/plugins"
      payload = {
          name: plugin
      }
      _config = config.deep_dup
      _config.keys.each do |k|
        _config['config.' + k.to_s] = _config.delete(k)
      end
      payload.merge!_config
      puts make_kong_request method, url, payload
    end

    def create_plugin_for_client(api_name, plugin, consumer_id, config = {})
      puts "Adding Plugin #{ plugin } for api #{ api_name }"
      method = :put
      url = "/apis/#{ api_name}/plugins"
      payload = { name: plugin, consumer_id: consumer_id }
      _config = config.deep_dup
      _config.keys.each do |k|
        _config['config.' + k.to_s] = _config.delete(k)
      end
      payload.merge!_config
      puts make_kong_request method, url, payload
    end

    private

    def create_key_auth_config(consumer_name, key)
      method = :post
      url = "/consumers/#{consumer_name}/key-auth"
      payload = {
          key: key
      }
      make_kong_request method, url, payload
    end

    def current_consumers
      make_kong_request :get, '/consumers/'
    end

    def current_api_names
      apis = make_kong_request :get, '/apis'
      apis['data'].collect { |x| x['name'] }
    end

    def enterprise_name_exists?(enterprise_name)
      Octo::Enterprise.all.select { |x| x.name == enterprise_name}.length > 0
    end

    def make_kong_request(method, url, payload = {})
      args = [@config[:kong] + url]
      if [:post, :put].include?method
        args << payload.to_json
        http = Curl.public_send(method, *args ) do |http|
          http.headers['Accept'] = 'application/json, text/plain, */*'
          http.headers['Content-Type'] = 'application/json;charset=UTF-8'
        end
      elsif method == :get
        http = Curl.public_send(method, *args ) do |http|
          http.headers['Accept'] = 'application/json, text/plain, */*'
        end
      end
      JSON.parse(http.body_str)
    end

  end


  class EnterpriseCreator

    extend Octo::EnterpriseGenetaor

    class << self

      def create(config_file_path)
        @config = YAML.load_file config_file_path

        # create APIs
        expected_api_names = @config[:apis].collect { |x| x[:name]}
        apis_to_create = expected_api_names - current_api_names

        apis_to_create.each do |api|
          api_config = @config[:apis].select { |x| x[:name] == api}.first
          create_api(api_config)
        end

        # create consumers
        @config[:clients].each do |enterprise|
          create_enterprise(enterprise)
        end

        consumer_info = current_consumers['data']

        # create Plugins
        @config[:plugins].each do |plugin_name, plugin_conf|
          apis = plugin_conf[:apis]
          clients = plugin_conf[:clients]
          config = plugin_conf[:config]
          apis.each do |api|
            if clients == 'all'
              create_plugin api, plugin_name, config
            else
              clients.each do |client|
                client_config = @config[:clients].select { |x| x[:name].to_s.downcase == client.to_s.downcase }.first
                client_plugin_config = client_config[plugin_name]
                consumer = consumer_info.select { |x| x['username'].to_s.downcase == client.to_s.downcase }.first
                create_plugin_for_client api, plugin_name, consumer['id'], client_plugin_config
              end
            end
          end
        end
      end
    end

  end
end

def help
  puts <<HELP
Usage:
./create_kong_config.rb path/to/kong_config.yaml

** Unable to find kong_config.yaml in current directory.
HELP
end

if __FILE__ == $0
  expected_file_path = File.join(File.expand_path(File.dirname(__FILE__)), 'kong_config.yaml')
  unless File.exist?expected_file_path
    if ARGV.length != 1
      help
    else
      expected_file_path = ARGV[0]
    end
  end
  Octo.connect_with_config_file(File.join(Dir.pwd, 'config.yml'))
  Octo::EnterpriseCreator.create expected_file_path
end