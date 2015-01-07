aws_config = Rails.root.join('config', 'aws.rb')
require aws_config if File.exists?(aws_config)

namespace :elb do
  task :allocate => ['vpc:initialize', 'vpc:allocate', 'vpc:subnet:allocate'] do
    subnet = @subnets[:public].first
    name = "#{@app_name}-#{ENV['APP_ENV']}-http"
    api = AWS::ELB::Client.new(region: @vpc_opts[:region])
    ec2 = AWS::EC2::Client.new(region: @vpc_opts[:region])
    unless @elb = api.describe_load_balancers[:load_balancer_descriptions].find{|desc| desc[:load_balancer_name] == name }
      @elb = api.
        create_load_balancer(load_balancer_name: name,
                             listeners: [{'Protocol'         => 'http',
                                          'LoadBalancerPort' => 80,
                                          'InstancePort'     => 80}],
                             subnets: [subnet[:subnet_id]])
    end
    @elb.update(name: name, security_groups: [])
    security_group = ec2
      .describe_security_groups(
        filters: [{'Name'  => 'vpc-id',
                   'Value' => [@vpc.vpc_id]}]
      )[:security_group_info].find{|g| g[:group_name] == 'AWS-OpsWorks-LB-Server' }

    api.apply_security_groups_to_load_balancer(
      load_balancer_name: name,
      security_groups: [security_group[:group_id]])
  end
end
