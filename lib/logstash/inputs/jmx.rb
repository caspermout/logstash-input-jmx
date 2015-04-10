# encoding: utf-8
require "logstash/inputs/base"
require "logstash/namespace"
require "logstash/json"

# This input plugin permits to retrieve metrics from remote Java applications using JMX.
# Every `polling_frequency`, it scans a folder containing json configuration 
# files describing JVMs to monitor with metrics to retrieve.
# Then a pool of threads will retrieve metrics and create events.
#
# ## The configuration:
#
# In Logstash configuration, you must set the polling frequency,
# the number of thread used to poll metrics and a directory absolute path containing
# json files with the configuration per jvm of metrics to retrieve.
# Logstash input configuration example:
# [source,ruby]
#     jmx {
#       //Required
#       path => "/apps/logstash_conf/jmxconf"
#       //Optional, default 60s
#       polling_frequency => 15
#       type => "jmx"
#       //Optional, default 4
#       nb_thread => 4
#     }
#
# Json JMX configuration example:
# [source,js]
#     {
#       //Required, JMX listening host/ip
#       "host" : "192.168.1.2",
#       //Required, JMX listening port
#       "port" : 1335,
#       //Optional, the username to connect to JMX
#       "username" : "user",
#       //Optional, the password to connect to JMX
#       "password": "pass",
#       //Optional, use this alias as a prefix in the metric name. If not set use <host>_<port>
#       "alias" : "test.homeserver.elasticsearch",
#       //Required, list of JMX metrics to retrieve
#       "queries" : [
#       {
#         //Required, the object name of Mbean to request
#         "object_name" : "java.lang:type=Memory",
#         //Optional, use this alias in the metrics value instead of the object_name
#         "object_alias" : "Memory"
#       }, {
#         "object_name" : "java.lang:type=Runtime",
#         //Optional, set of attributes to retrieve. If not set retrieve
#         //all metrics available on the configured object_name.
#         "attributes" : [ "Uptime", "StartTime" ],
#         "object_alias" : "Runtime"
#       }, {
#         //object_name can be configured with * to retrieve all matching Mbeans
#         "object_name" : "java.lang:type=GarbageCollector,name=*",
#         "attributes" : [ "CollectionCount", "CollectionTime" ],
#         //object_alias can be based on specific value from the object_name thanks to ${<varname>}.
#         //In this case ${type} will be replaced by GarbageCollector...
#         "object_alias" : "${type}.${name}"
#       }, {
#         "object_name" : "java.nio:type=BufferPool,name=*",
#         "object_alias" : "${type}.${name}"
#       } ]
#     }
#
# Here are examples of generated events. When returned metrics value type is 
# number/boolean it is stored in `metric_value_number` event field
# otherwise it is stored in `metric_value_string` event field.
# [source,ruby]
#     {
#       "@version" => "1",
#       "@timestamp" => "2014-02-18T20:57:27.688Z",
#       "host" => "192.168.1.2",
#       "path" => "/apps/logstash_conf/jmxconf",
#       "type" => "jmx",
#       "metric_path" => "test.homeserver.elasticsearch.GarbageCollector.ParNew.CollectionCount",
#       "metric_value_number" => 2212
#     }
#
# [source,ruby]
#     {
#       "@version" => "1",
#       "@timestamp" => "2014-02-18T20:58:06.376Z",
#       "host" => "localhost",
#       "path" => "/apps/logstash_conf/jmxconf",
#       "type" => "jmx",
#       "metric_path" => "test.homeserver.elasticsearch.BufferPool.mapped.ObjectName",
#       "metric_value_string" => "java.nio:type=BufferPool,name=mapped"
#     }
#
class LogStash::Inputs::Jmx < LogStash::Inputs::Base
  config_name 'jmx'

  #Class Var
  attr_accessor :regexp_group_alias_object
  attr_accessor :queue_conf

  # Path where json conf files are stored
  config :path, :validate => :string, :required => true

  # Indicate interval between two jmx metrics retrieval
  # (in s)
  config :polling_frequency, :validate => :number, :default => 60

  # Indicate number of thread launched to retrieve metrics
  config :nb_thread, :validate => :number, :default => 4

  # Read and parse json conf
  private
  def read_conf(file_conf)
    @logger.debug("Parse json #{file_conf} to ruby data structure")
    json = File.read(file_conf)
    LogStash::Json.load(json)
  end

  # Verify that all required parameter are present in the conf_hash
  private
  def check_conf(conf_hash,file_conf)
    #Check required parameters
    @logger.debug("Check that required parameters are define with good types in #{conf_hash}")
    parameter = {'host' => 'String'.class, 'port' => 1.class, 'queries' => [].class}
    parameter.each_key do |param|
      if conf_hash.has_key?(param)
        unless conf_hash[param].instance_of?(parameter[param])
          @logger.error("Bad syntax for conf file #{file_conf}. Bad types for parameter #{param}, expecting #{parameter[param]}, found #{conf_hash[param].class}.")
          return false
        end
      else
        @logger.error("Bad syntax for conf file #{file_conf}. Missing parameter #{param}.")
        return false
      end
    end

    @logger.debug('Check optional parameters types')
    parameter = {'alias' => 'String'.class}
    parameter.each_key do |param|
      if conf_hash.has_key?(param)
        unless conf_hash[param].instance_of?(parameter[param])
          @logger.error("Bad syntax for conf file #{file_conf}. Bad types for parameter #{param}, expecting #{parameter[param]}, found #{conf_hash[param].class}.")
          return false
        end
      end
    end

    @logger.debug('Check that required parameters are define with good types for queries')
    parameter = {'object_name' => 'String'.class}
    parameter.each_key do |param|
      conf_hash['queries'].each do |query|
        if query.has_key?(param)
          unless query[param].instance_of?(parameter[param])
            @logger.error("Bad syntax for conf file #{file_conf}. Bad types for parameter #{param} in query #{query}, expecting #{parameter[param]}, found #{conf_hash[param].class}.")
            return false
          end
        else
          @logger.error("Bad syntax for conf file #{file_conf} in query #{query}. Missing parameter #{param}.")
          return false
        end
      end
    end

    @logger.debug('Check optional parameters types for queries')
    parameter = {'object_alias' => 'String'.class, 'attributes' => [].class}
    parameter.each_key do |param|
      conf_hash['queries'].each do |query|
        if query.has_key?(param)
          unless query[param].instance_of?(parameter[param])
            @logger.error("Bad syntax for conf file #{file_conf} in query #{query}. Bad types for parameter #{param}, expecting #{parameter[param]}, found #{conf_hash[param].class}.")
            return false
          end
        end
      end
    end

    true
  end

  private
  def replace_alias_object(r_alias_object,object_name)
    @logger.debug("Replace ${.*} variables from #{r_alias_object} using #{object_name}")
    group_alias = @regexp_group_alias_object.match(r_alias_object)
    if group_alias
      r_alias_object = r_alias_object.gsub('${'+group_alias[1]+'}',object_name.split(group_alias[1]+'=')[1].split(',')[0])
      r_alias_object = replace_alias_object(r_alias_object,object_name)
    end
    r_alias_object
  end

  private
  def send_event_to_queue(queue,host,metric_path,metric_value)
    @logger.debug('Send event to queue to be processed by filters/outputs')
    event = LogStash::Event.new
    event['host'] = host
    event['path'] = @path
    event['type'] = @type
    number_type = [Fixnum, Bignum, Float]
    boolean_type = [TrueClass, FalseClass]
    metric_path_substituted = metric_path.gsub(' ','_').gsub('"','')
    if number_type.include?(metric_value.class)
      @logger.debug("The value #{metric_value} is of type number: #{metric_value.class}")
      event['metric_path'] = metric_path_substituted
      event['metric_value_number'] = metric_value
    elsif boolean_type.include?(metric_value.class)
      @logger.debug("The value #{metric_value} is of type boolean: #{metric_value.class}")
      event['metric_path'] = metric_path_substituted+'_bool'
      event['metric_value_number'] = metric_value ? 1 : 0
    else
      @logger.debug("The value #{metric_value} is not of type number: #{metric_value.class}")
      event['metric_path'] = metric_path_substituted
      event['metric_value_string'] = metric_value.to_s
    end
    queue << event
  end

  # Thread function to retrieve metrics from JMX
  private
  def thread_jmx(queue_conf,queue)
    require 'jmx4r'

    while true
      begin
        @logger.debug('Wait config to retrieve from queue conf')
        thread_hash_conf = queue_conf.pop
        @logger.debug("Retrieve config #{thread_hash_conf} from queue conf")

        @logger.debug('Check if jmx connection need a user/password')
        if thread_hash_conf.has_key?('username') and thread_hash_conf.has_key?('password')
          @logger.debug("Connect to #{thread_hash_conf['host']}:#{thread_hash_conf['port']} with user #{thread_hash_conf['username']}")
          jmx_connection = JMX::MBean.connection :host => thread_hash_conf['host'],
                                                 :port => thread_hash_conf['port'],
                                                 :username => thread_hash_conf['username'],
                                                 :password => thread_hash_conf['password']
        else
          @logger.debug("Connect to #{thread_hash_conf['host']}:#{thread_hash_conf['port']}")
          jmx_connection = JMX::MBean.connection :host => thread_hash_conf['host'],
                                                 :port => thread_hash_conf['port']
        end


        if thread_hash_conf.has_key?('alias')
          @logger.debug("Set base_metric_path to alias: #{thread_hash_conf['alias']}")
          base_metric_path = thread_hash_conf['alias']
        else
          @logger.debug("Set base_metric_path to host_port: #{thread_hash_conf['host']}_#{thread_hash_conf['port']}")
          base_metric_path = "#{thread_hash_conf['host']}_#{thread_hash_conf['port']}"
        end


        @logger.debug("Treat queries #{thread_hash_conf['queries']}")
        thread_hash_conf['queries'].each do |query|
          @logger.debug("Find all objects name #{query['object_name']}")
          jmx_object_name_s = JMX::MBean.find_all_by_name(query['object_name'], :connection => jmx_connection)

          if jmx_object_name_s.length > 0
            jmx_object_name_s.each do |jmx_object_name|
              if query.has_key?('object_alias')
                object_name = replace_alias_object(query['object_alias'],jmx_object_name.object_name.to_s)
                @logger.debug("Set object_name to object_alias: #{object_name}")
              else
                object_name = jmx_object_name.object_name.to_s
                @logger.debug("Set object_name to jmx object_name: #{object_name}")
              end

              if query.has_key?('attributes')
                @logger.debug("Retrieves attributes #{query['attributes']} to #{jmx_object_name.object_name}")
                query['attributes'].each do |attribute|
                  begin
                    jmx_attribute_value = jmx_object_name.send(attribute.snake_case)
                    if jmx_attribute_value.instance_of? Java::JavaxManagementOpenmbean::CompositeDataSupport
                      @logger.debug('The jmx value is a composite_data one')
                      jmx_attribute_value.each do |jmx_attribute_value_composite|
                        @logger.debug("Get jmx value #{jmx_attribute_value[jmx_attribute_value_composite]} for attribute #{attribute}.#{jmx_attribute_value_composite} to #{jmx_object_name.object_name}")
                        send_event_to_queue(queue, thread_hash_conf['host'], "#{base_metric_path}.#{object_name}.#{attribute}.#{jmx_attribute_value_composite}", jmx_attribute_value[jmx_attribute_value_composite])
                      end
                    else
                      @logger.debug("Get jmx value #{jmx_attribute_value} for attribute #{attribute} to #{jmx_object_name.object_name}")
                      send_event_to_queue(queue, thread_hash_conf['host'], "#{base_metric_path}.#{object_name}.#{attribute}", jmx_attribute_value)
                    end
                  rescue Exception => ex
                    @logger.warn("Failed retrieving metrics for attribute #{attribute} on object #{jmx_object_name.object_name}")
                    @logger.warn(ex.message)
                  end
                end
              else
                @logger.debug("No attribute to retrieve define on #{jmx_object_name.object_name}, will retrieve all")
                jmx_object_name.attributes.each_key do |attribute|
                  begin
                    jmx_attribute_value = jmx_object_name.send(attribute)
                    if jmx_attribute_value.instance_of? Java::JavaxManagementOpenmbean::CompositeDataSupport
                      @logger.debug('The jmx value is a composite_data one')
                      jmx_attribute_value.each do |jmx_attribute_value_composite|
                        @logger.debug("Get jmx value #{jmx_attribute_value[jmx_attribute_value_composite]} for attribute #{jmx_object_name.attributes[attribute]}.#{jmx_attribute_value_composite} to #{jmx_object_name.object_name}")
                        send_event_to_queue(queue, thread_hash_conf['host'], "#{base_metric_path}.#{object_name}.#{jmx_object_name.attributes[attribute]}.#{jmx_attribute_value_composite}", jmx_attribute_value[jmx_attribute_value_composite])
                      end
                    else
                      @logger.debug("Get jmx value #{jmx_attribute_value} for attribute #{jmx_object_name.attributes[attribute]} to #{jmx_object_name.object_name}")
                      send_event_to_queue(queue, thread_hash_conf['host'], "#{base_metric_path}.#{object_name}.#{jmx_object_name.attributes[attribute]}", jmx_attribute_value)
                    end
                  rescue Exception => ex
                    @logger.warn("Failed retrieving metrics for attribute #{attribute} on object #{jmx_object_name.object_name}")
                    @logger.warn(ex.message)
                  end
                end
              end
            end
          else
            @logger.warn("No jmx object found for #{query['object_name']}")
          end
        end
        jmx_connection.close
      rescue Exception => ex
        @logger.error(ex.message)
        @logger.error(ex.backtrace.join("\n"))
      end
    end
  end

  public
  def register
    @logger.info('Registering files in', :path => @path)

    @logger.info('Create queue conf used to send jmx conf to jmx collector threads')
    @queue_conf = Queue.new

    @logger.info('Compile regexp for group alias object replacement')
    @regexp_group_alias_object = Regexp.new('(?:\${(.*?)})+')
  end

  public
  def run(queue)
    require 'thread'

    begin
      threads = []
      @logger.info("Init #{@nb_thread} jmx collector threads")
      @nb_thread.times do
        threads << Thread.new { thread_jmx(@queue_conf,queue) }
      end

      while true
        @logger.info("Load conf files in #{@path}")
        Dir.foreach(@path) do |item|
          begin
            next if item == '.' or item == '..'
            file_conf = File.join(@path, item)
            @logger.debug("Load conf file #{file_conf}")
            conf_hash = read_conf(file_conf)
            if check_conf(conf_hash,file_conf)
              @logger.debug("Add conf #{conf_hash} to the queue conf")
              @queue_conf << conf_hash
            end
          rescue Exception => ex
            @logger.warn("Issue parsing file #{file_conf}")
            @logger.warn(ex.message)
            @logger.warn(ex.backtrace.join("\n"))
            next
          end
        end
        @logger.debug('Wait until the queue conf is empty')
        delta=0
        until @queue_conf.empty?
          @logger.debug("There are still #{@queue_conf.size} messages in the queue conf. Sleep 1s.")
          delta=delta+1
          sleep(1)
        end
        wait_time=@polling_frequency-delta
        if wait_time>0
          @logger.debug("Wait #{wait_time}s (#{@polling_frequency}-#{delta}(seconds wait until queue conf empty)) before to launch again a new jmx metrics collection")
          sleep(wait_time)
        else
          @logger.warn("The time taken to retrieve metrics is more important than the retrieve_interval time set.
                       \nYou must adapt nb_thread, retrieve_interval to the number of jvm/metrics you want to retrieve.")
        end
      end
    rescue Exception => ex
      @logger.error(ex.message)
      @logger.error(ex.backtrace.join("\n"))
    end
  end
end
