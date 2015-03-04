aws_config = Rails.root.join('config', 'aws.rb')
require aws_config if File.exists?(aws_config)

ENV_NAMES = {stg: 'staging', prod: 'production'} unless defined?(ENV_NAMES)

namespace :rds do
  task :setup => ["rds:subnet_group:create", "rds:parameter_group:create", "rds:instance:create"]

  task :initialize do
    @rds_config = Configure.new('rds').parse.update(Configure.new('vpc').parse)
    @rds  = AWS::RDS::Client.new(region: @rds_config[:region])
    @rds.instance_variable_set(:@endpoint, "rds.#{@rds_config[:region]}.amazonaws.com")
    @subnet_group_name    = @rds_config[:subnet_group_name]
    @parameter_group_name = @rds_config[:charaset].downcase
    @charset              = @rds_config[:charaset]
  end

  task :vpc => ['vpc:allocate'] do
    ec2 = AWS::EC2.new(region: @rds_config[:region])
    @vpc = ec2.vpcs[@vpc[:vpc_id]]
  end

  namespace :subnet_group do
    task :create => [:initialize, 'vpc:subnet:allocate'] do
      unless @rds.describe_db_subnet_groups[:db_subnet_groups].find{|_| _[:db_subnet_group_name] == @subnet_group_name}
        subnet_ids =  @subnets[:private].map{|subnet| subnet[:subnet_id]}
        @rds.create_db_subnet_group(db_subnet_group_name: @subnet_group_name,
                                    db_subnet_group_description: "#{@app_name} game subnet.",
                                    subnet_ids: subnet_ids)
      end
    end
  end

  namespace :parameter_group do
    task :create => [:initialize] do
         unless @rds.describe_db_parameter_groups[:db_parameter_groups].find{|_| _[:db_parameter_group_name] == @parameter_group_name }
        @rds.create_db_parameter_group(db_parameter_group_name: @parameter_group_name,
                                       db_parameter_group_family: @rds_config[:dbms],
                                       description: 'Use Unicode character')
      end
      params = []
      if @character == "utf8mb4"
        params = %w(character_set_database
                    character_set_client
                    character_set_connection
                    character_set_results
                    character_set_server).map{|name|
          {parameter_name:   name,
           parameter_value:  @charset,
           apply_method:    'pending-reboot'}
        } 
        params += {'skip-character-set-client-handshake' => '1',
                   'innodb_file_format'                  => 'Barracuda',
                   'innodb_file_per_table'               => '1',
                   'innodb_large_prefix'                 => '1'}.map{|k, v|
          {parameter_name:  k,
            parameter_value: v,
            apply_method:    'pending-reboot'}
        }
      end

      @rds.modify_db_parameter_group(
        db_parameter_group_name: @parameter_group_name,
        parameters: params)
    end
  end

  namespace :instance do
    task :create => [:initialize, 'rds:security_groups:index'] do
      begin
        security_group_ids = @security_groups.select{|_| _.name == 'AWS-OpsWorks-DB-Master-Server' }.map(&:id)
        params = instance_params
        params.update(allocated_storage:    @rds_config[:storage_gigabyte].to_i,
                      master_username:      db_name,
                      master_user_password: ENV['AWS_ACCESS_KEY_ID'],
                      db_name:              db_name,
                      db_parameter_group_name: @parameter_group_name,
                      engine_version:          @rds_config[:dbms_version],
                      vpc_security_group_ids:  security_group_ids)

        @rds.create_db_instance(params)
      rescue AWS::RDS::Errors::DBInstanceAlreadyExists
        # DO NOTHING
      end
    end

    task :show => [:initialize] do
      timeout 60 * 10 do
        loop do
          @rds_instances = @rds.describe_db_instances[:db_instances]
          @rds_instance = @rds_instances.find{|_| _[:db_instance_identifier] == @rds_config[:instance_id] }
          @rds_readreplicas = @rds_instances.select{|_| _[:read_replica_source_db_instance_identifier] == @rds_config[:instance_id] }
          break nil unless @rds_instance
          break if @rds_instance[:db_instance_status] == 'available'
          puts "#{Time.now.strftime("%F %T")} - Waing RDS boot ..."
          sleep 30
        end
      end
    end
  end

  namespace :security_groups do
    task :index => [:initialize, :vpc] do
      @security_groups = @vpc.security_groups
    end
  end

  %i(stg prod).each do |env|
    namespace env do
      task :set_env do
        ENV['APP_ENV'] = env.to_s
        ENV['RAILS_ENV'] = {stg: 'staging', prod: 'production'}[env]
      end

      namespace :read_replica do
        task :create => [:set_env, 'rds:read_replica:create']
      end

      desc "create #{env} final snapshot and stop RDS instance"
      task :stop => [:set_env, 'rds:stop']

      desc "restart RDS instance using #{env} final snapshot"
      task :restart => [:set_env, 'rds:restart']
    end
  end

  namespace :read_replica do
    desc "create RDS read replica"
    task :create => [:initialize, "rds:instance:show"] do
      @rds.create_db_instance_read_replica(
        source_db_instance_identifier:  @rds_config[:instance_id],
        db_instance_class:              @rds_config[:instance_class],
        db_instance_identifier:         "#{@rds_config[:instance_id]}#{@rds_instances.count}")
      Rake::Task["opsworks:stack:update"].invoke
    end
  end

  task :stop => [:initialize, "rds:instance:show"] do
    @rds.delete_db_instance(db_instance_identifier: @rds_config[:instance_id],
                            final_db_snapshot_identifier: snapshot_name)
  end

  task :restart => [:initialize, "rds:instance:show", "rds:security_groups:index"] do
    params = instance_params
    params.update(db_snapshot_identifier: snapshot_name)
    @rds.restore_db_instance_from_db_snapshot(params)
  end

  def snapshot_name
    @rds_config[:instance_id] + "-final"
  end

  def db_name
    @rds_config[:instance_id].gsub(/\-/, '_')
  end

  def instance_params
    engine = @rds_config[:dbms].gsub(/[0-9\.]+$/, '')
    {storage_type:            "gp2",
     engine:                  engine,
     db_instance_identifier:  @rds_config[:instance_id],
     db_instance_class:       @rds_config[:instance_class],
     db_subnet_group_name:    @subnet_group_name,
     multi_az:                @rds_config[:multi_az]}
  end
end
