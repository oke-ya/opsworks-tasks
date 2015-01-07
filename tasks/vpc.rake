aws_config = Rails.root.join('config', 'aws.rb')
require aws_config if File.exists?(aws_config)

namespace :vpc do
  task :initialize do
    @vpc_opts = Configure.new('vpc').parse
    @app_name = ENV["STACK_NAME"]
    @ec2 = AWS::EC2::Client.new(region: @vpc_opts[:region])
  end

  task :allocate => [:initialize] do
    unless @vpc = @ec2.describe_vpcs[:vpc_set].find{|vpc| vpc[:tag_set].find{|tag| tag[:key] == 'application' && tag[:value] == @app_name } }
      @vpc = @ec2.create_vpc(cidr_block: @vpc_opts[:cidr_block])[:vpc]
      @ec2.create_tags(resources: [@vpc[:vpc_id]],
                       tags: [{'Key' => 'application', 'Value' => @app_name}])
      internet_gateway = @ec2.create_internet_gateway[:internet_gateway]
      @ec2.attach_internet_gateway(internet_gateway_id: internet_gateway[:internet_gateway_id],
                                   vpc_id: @vpc[:vpc_id])
    end
    Rake::Task['vpc:subnet:allocate']
    route_table = @ec2.describe_route_tables[:route_table_set].find{|table_set| table_set[:vpc_id] == @vpc[:vpc_id] }
    unless route_table[:route_set].find{|set| set[:destination_cidr_block] == '0.0.0.0/0'}
      gateway = @ec2.describe_internet_gateways[:internet_gateway_set].find{|gateway|
        gateway[:attachment_set].find{|attachment|
          attachment[:vpc_id] == @vpc[:vpc_id]
        }
      }
      @ec2.create_route(route_table_id: route_table[:route_table_id],
                        gateway_id:     gateway[:internet_gateway_id],
                        destination_cidr_block: '0.0.0.0/0')
    end

    @ec2.modify_vpc_attribute(vpc_id: @vpc[:vpc_id],
                              enable_dns_hostnames: {'Value' => true})
    @vpc
  end

  namespace :subnet do
    task :create, [:types, :zone_names] do |task, args|
      zone_names = args.zone_names
      i = 0
      @subnets = zone_names.inject(Hash.new) do |hash, name|
        args.types.map{|type|
          hash[type] ||= []
          (address, mask) = @vpc_opts[:cidr_block].split('/')
          address_numbers = address.split('.')
          address_numbers[2] = i
          cidr = address_numbers.join('.') + '/' + '24'
          i += 1
          hash[type] << @ec2.create_subnet(vpc_id:            @vpc[:vpc_id],
                                           cidr_block:        cidr,
                                           availability_zone: name)[:subnet]


        }
        hash
      end
    end

    task :allocate => ['vpc:allocate'] do
      subnets = @ec2.describe_subnets(
                  filters: [{'Name'  => 'vpc-id',
                             'Value' => [@vpc[:vpc_id]]}])[:subnet_set]
      zone_names = @ec2.describe_availability_zones[:availability_zone_info].map{|zone| zone[:zone_name] }
      types = [:public, :private]

      if subnets.count < (zone_names.count * types.count)
        Rake::Task['vpc:subnet:create'].invoke(types, zone_names)
      else
        keys = {false => :public, true => :private}
        @subnets = subnets.group_by{|subnet|
          bool = subnet[:cidr_block].split(%r|[/\.]|)[2].to_i.odd?
          keys[bool]
        }
      end
    end
  end

  namespace :security_group do
    task :index => [:initialize] do
      @security_groups = @ec2.describe_security_groups[:security_group_info]
    end
  end
end
