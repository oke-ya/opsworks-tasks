# -*- coding: utf-8 -*-
aws_config = Rails.root.join('config', 'aws.rb')
require aws_config if File.exists?(aws_config)
require 'timeout'

namespace :opsworks do
  task :install do
    Dir.glob(File.expand_path('../../config/*.rb', __FILE__)) do |f|
      FileUtils.cp f, Rails.root.join("config", File.basename(f))
    end
  end

  task :setup => ["rds:setup",
                  "opsworks:stack:allocate",
                  "opsworks:layer:allocate",
                  "opsworks:instance:create",
                  "opsworks:app:allocate"]

  task :initialize do
    @opsworks = AWS::OpsWorks::Client.new
    @opts     = Configure.new('opsworks').parse.update(Configure.new('vpc').parse)
  end

  %i(stg prod).each do |env|
    namespace env do
      task :initialize do
        ENV['APP_ENV'] = env.to_s
      end

      %i(setup deploy migrations seed start stack:update layer:update).each do |name|
        desc "#{name} AWS OpsWorks stack #{env} ENV"
        task_name = [:setup, :deploy, :'stack:update', :'layer:update'].include?(name) ? name : :"deploy:#{name}"
        task name => [:initialize, "opsworks:#{task_name}"]
      end
    end
  end

  namespace :stack do
    task :config => [:initialize, 'vpc:allocate', 'vpc:subnet:allocate', 'rds:instance:show'] do
      oauth = Configure.new('.oauth').parse
      @stack_name = @opts[:stack_name]
      database = {username: @rds_instance[:master_username],
                  password: ENV['AWS_ACCESS_KEY_ID'],
                  encoding: 'utf8mb4',
                  host:     @rds_instance[:endpoint][:address],
                  port:     @rds_instance[:endpoint][:port],
                  database: @stack_name,
                  reconnect: true}
      read_replicas = @rds_readreplicas.map{|_| _[:endpoint] }
      symlink_before_migrate = {"config/shards.yml" => "config/shards.yml"}
      custom_json = {
        content: {domain: @opts[:domain],
                  title:  @opts[:title]},
        opensocial: {key:    oauth[:consumer_key],
                     secret: oauth[:consumer_secret],
                     app_id: oauth[:app_id]},
        github: {token: oauth[:github_token]},
        deploy:     {@stack_name => {database:               database,
                                     read_replicas:          read_replicas,
                                     symlink_before_migrate: symlink_before_migrate}}
      }

      if ENV['APP_ENV'] == 'prod'
        # Rake::Task["elasti_cache:instance:show"].invoke
        # end_point = @elasti_cache_instance[:configuration_endpoint]
        # custom_json[:deploy][@stack_name][:memcached] =
        #   {host: end_point[:address],
        #    port: end_point[:port]}

        Rake::Task["s3:bucket:create"].invoke
        custom_json[:s3] = {
          access_key:    ENV['AWS_ACCESS_KEY_ID'],
          access_secret: ENV['AWS_SECRET_ACCESS_KEY'],
          bucket:        @bucket.name,
          end_point:     @s3.config.s3_endpoint
        }
        custom_json[:td_agent] = {includes: true}
      else
        custom_json[:opensocial][:sandbox] = true
      end

      @stack_config =
      {name:                         @stack_name,
       custom_json:                  custom_json.to_json,
       service_role_arn:             @opts[:service_role_arn],
       default_instance_profile_arn: @opts[:default_instance_profile_arn],
       configuration_manager: {name: 'Chef', version: @opts[:chef_version]},
       use_custom_cookbooks: true,
       custom_cookbooks_source: {type: 'git', url: 'https://github.com/oke-ya/cookbooks.git'},
       default_subnet_id: @subnets[:public].first[:subnet_id] }
    end

    task :allocate => [:show] do
      op = (@stack_id) ? 'update' : 'create'
      Rake::Task["opsworks:stack:#{op}"].invoke
    end

    task :show => [:initialize, :config] do
      if stack = @opsworks.describe_stacks[:stacks].find{|_| _[:name] == @stack_name }
        @stack_id = stack[:stack_id]
      end
    end

    task :create => [:initialize, :config] do
      stack = @opsworks.create_stack({region: @opts[:region],
                                      vpc_id: @vpc.vpc_id,
}.update(@stack_config))
      @stack_id = stack[:stack_id]
    end

    task :update => [:show] do
      @opsworks.update_stack({stack_id: @stack_id}.update(@stack_config))
    end
  end

  namespace :layer do
    task :config => [:initialize] do
      @layer_name = 'Rails Application Server'
      setup     = ["bower", "opensocial", "nginx_repository", "rails::shards"]
      configure = []
      deploy    = ["github::public_key"]
      shutdown  = []

      if ENV['APP_ENV'] != 'prod'
        setup    << "memcached"
        shutdown << 'memcached::stop'
      else
        setup    << "memcached"
        shutdown << 'memcached::stop'
        setup << "fluentd_nginx"
      end
      @layer_config =
        {name:      @layer_name,
         shortname: 'app',
         attributes: {
           'RubyVersion'     => @opts[:ruby_version],
           'BundlerVersion'  => @opts[:bundler_version],
           'RubygemsVersion' => @opts[:rubygems_version],
           'RailsStack'      => @opts[:rails_stack]},
         custom_recipes: {'Setup'     => setup,
                          'Configure' => configure,
                          'Deploy'    => deploy,
                          'Shutdown'  => shutdown},
         auto_assign_elastic_ips: false,
         auto_assign_public_ips: true}
    end

    task :allocate => [:show, 'opsworks:stack:allocate', 'elb:allocate'] do
      op = (@layer_id) ? 'update' : 'create'
      Rake::Task["opsworks:layer:#{op}"].invoke
      @opsworks.attach_elastic_load_balancer(elastic_load_balancer_name: @elb[:name], layer_id: @layer_id)
    end

    task :show => [:initialize, :config, 'opsworks:stack:show'] do
      if layer = @opsworks.describe_layers(stack_id: @stack_id)[:layers].find{|_| _[:name] == @layer_name }
        @layer_id = layer[:layer_id]
      end
    end

    task :create => [:initialize, :config, 'opsworks:stack:show'] do
      layer = @opsworks.create_layer({stack_id: @stack_id,
                                      type: 'rails-app'}.update(@layer_config))
      @layer_id = layer[:layer_id]
    end

    task :update => [:show] do
      @opsworks.update_layer({layer_id: @layer_id}.update(@layer_config))
    end
  end

  namespace :instance do
    task :create => [:initialize, 'opsworks:layer:show', 'opsworks:stack:show', 'opsworks:instance:index'] do
      hostname = @opsworks.get_hostname_suggestion(layer_id: @layer_id)
      @opsworks.create_instance(hostname:         hostname[:hostname],
                                stack_id:         @stack_id,
                                layer_ids:        [@layer_id],
                                ssh_key_name:     @opts[:ssh_key],
                                instance_type:    @opts[:instance_type],
                                os:               'Ubuntu 12.04 LTS',
                                root_device_type: 'ebs')
    end

    task :index => [:initialize, "opsworks:layer:show"] do
      @instances = @opsworks.describe_instances(layer_id: @layer_id)[:instances]
    end

    task :start => [:initialize, "opsworks:instance:index"] do
      @instances.select{|instance| instance[:status] == 'stopped' }.each do |instance|
        @opsworks.start_instance(instance_id: instance[:instance_id])
      end
    end
  end

  namespace :app do
    task :config do
      @app_config = {type:       'rails',
                 app_source: {type:     'git',
                              ssh_key:  File.read(@opts[:deploy_key_local_path]),
                              url:      @opts[:repository],
                              revision: @opts[:branch]},
                 attributes: {'RailsEnv'           => @opts[:rails_env],
                              'AutoBundleOnDeploy' => 'true',
                              'DocumentRoot'       => 'public'}}
    end

    task :allocate => [:initialize, :index]do
      if @apps.count < 1
        Rake::Task["opsworks:app:create"].invoke
      else
        Rake::Task["opsworks:app:update"].invoke
      end
    end

    task :index => [:initialize, 'opsworks:stack:show'] do
      @apps = @opsworks.describe_apps(stack_id: @stack_id)[:apps]
    end

    task :create => [:initialize, :index, :config, 'opsworks:stack:show'] do
      @opsworks.create_app({name:      @stack_name,
                            shortname: @stack_name,
                            stack_id:  @stack_id}.update(@app_config))
    end

    task :update => [:initialize, :index, :config] do
      @apps.each do |app|
        @opsworks.update_app({app_id: app[:app_id]}.update(@app_config))
      end
    end
  end

  task :deploy => 'deploy:execute'
  namespace :deploy do
    task :prepare_instances => [:initialize] do
      Rake::Task["opsworks:instance:index"].invoke
      if @instances.count < 1
        Rake::Task["opsworks:instance:create"]
      end

      Rake::Task["rds:instance:show"].invoke
      timeout 60 * 10 do
        loop do
          break if @instances.find{|instance| instance[:status] == 'online' }
          puts "#{Time.now.strftime("%F %T")} - Waing instance boot ..."
          sleep 30
        end
      end
    end

    task :execute, ['opts'] => [:initialize, 'opsworks:app:index', "opsworks:stack:update", "opsworks:layer:update"] do |t, args|
      options = {deploy: {@stack_name => {asset: true}}}
      if ENV['APP_ENV'] == 'prod'
        # Rake::Task["elasti_cache:instance:show"].invoke
        # options[:deploy][@stack_name][:memcached] = {
        #   host: @elasti_cache_instance[:address]
        # }
      end
      if args.opts
        options[:deploy][@stack_name][:migrate] = true if args.opts[:migrate]
        options[:deploy][@stack_name][:seed]    = true if args.opts[:seed]
      end

      Rake::Task['opsworks:deploy:run'].invoke('deploy', options)
    end

    task :migrations => [:prepare_instances]do
      Rake::Task['opsworks:deploy:execute'].invoke(migrate: true)
    end

    task :seed => [:prepare_instances] do
      Rake::Task['opsworks:deploy:execute'].invoke(migrate: true, seed: true)
    end

    task :run, ['cmd', 'options'] => [:initialize, 'opsworks:app:index'] do |t, args|
      @apps.each do |app|
        @opsworks.create_deployment(stack_id: app[:stack_id],
                                    app_id:   app[:app_id],
                                    custom_json:  args.options ? args.options.to_json : "{}" ,
                                    command:      {'Name' => args.cmd})
      end
    end

    task :start => [:initialize] do
      Rake::Task['opsworks:deploy:run'].invoke('start')
    end
  end
end
