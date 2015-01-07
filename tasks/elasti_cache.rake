namespace :elasti_cache do
  task :initialize do
    ENV['APP_ENV'] = 'prod'
    @cache_opts = Configure.new('opsworks').parse.update(Configure.new('vpc').parse)
    @elasti_cache = AWS::ElastiCache::Client.new(region: @cache_opts[:region])
    @subnet_group_name = @cache_opts[:stack_name]
  end

  namespace :instance do
    task :create => [:initialize, 'vpc:subnet:allocate', 'vpc:security_group:index', 'elasti_cache:subnet_group:create'] do
      vpc_id = @subnet_groups[:vpc_id]
      security_groups = @security_groups.select{|_|
        _[:group_name] == 'AWS-OpsWorks-Memcached-Server' && _[:vpc_id] == vpc_id
      }
      @elasti_cache.create_cache_cluster(
        cache_cluster_id:        @cache_opts[:stack_name],
        cache_node_type:         @cache_opts[:memcache_instance_type],
        cache_subnet_group_name: @subnet_group_name,
        security_group_ids:      security_groups.map{|_| _[:group_id] },
        engine:                  'memcached',
        num_cache_nodes:         1
      )
    end

    task :show => [:initialize] do
      @elasti_cache_instance = @elasti_cache.describe_cache_clusters[:cache_clusters].find{|_|
        _[:cache_cluster_id] == @cache_opts[:stack_name]
      }
    end
  end

  namespace :subnet_group do
    task :create => [:initialize, 'vpc:subnet:allocate'] do

      unless @subnet_groups = @elasti_cache.describe_cache_subnet_groups[:cache_subnet_groups].find{|_| _[:cache_subnet_group_name] == @subnet_group_name}
        subnet_ids =  @subnets[:private].map{|subnet| subnet[:subnet_id]}
        @subnet_groups = @elasti_cache.create_cache_subnet_group(
          cache_subnet_group_name:        @subnet_group_name,
          cache_subnet_group_description: "#{@subnet_group_name} game subnet.",
          subnet_ids: subnet_ids)
      end
    end
  end
end
