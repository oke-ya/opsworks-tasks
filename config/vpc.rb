region       ENV["AWS_REGION"]
cidr_block   ENV["CIDR"]
case ENV['RAILS_ENV']
when 'staging'
  domain ENV["DOMAIN"].split(".").tap{|a| a[0] += '-stg' }.join(".")
when 'production'
  domain ENV["DOMAIN"]
else
  raise
end
