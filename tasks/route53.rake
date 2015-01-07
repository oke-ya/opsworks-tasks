aws_config = Rails.root.join('config', 'aws.rb')
require aws_config if File.exists?(aws_config)

namespace :route53 do
  task :allocate => ['elb:allocate'] do
    @opts = Configure.new('vpc').parse
    route53 = AWS::Route53::Client.new(region: @opts[:region])
    domain = @opts[:domain] + '.'
    zone = route53.list_hosted_zones[:hosted_zones].find{|zone|
      domain =~ /#{zone[:name]}/
    }
    records = route53.list_resource_record_sets(hosted_zone_id: zone[:id])[:resource_record_sets]
    require 'pp'

    query = {
      hosted_zone_id: zone[:id],
      change_batch: {
        changes: [
                  {action: 'CREATE',
                   resource_record_set: {
                      ttl: 300,
                      resource_records: [{value: @elb[:dns_name]}],
                      type: 'CNAME',
                      name: @opts[:domain]
                    }
                  }
                 ]
      }
    }

    if record = records.find{|record| record[:name] == domain }
      next if record[:resource_records].first[:value] == @elb[:dns_name]
      delete_query = query.clone.tap{|_|
        _[:change_batch][:changes].first[:action] = 'DELETE'
      }
      route53.change_resource_record_sets(delete_query)
    end
    route53.change_resource_record_sets(query)
  end
end

