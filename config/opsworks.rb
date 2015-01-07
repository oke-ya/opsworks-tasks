# -*- coding: utf-8 -*-
case ENV['RAILS_ENV']
when 'staging'
  stack_name    "#{ENV["STACK_NAME"]}-stg"
  branch        'master'
  instance_type 'm2.micro'
  rails_env     'staging'
when 'production'
  stack_name    ENV["STACK_NAME"]
  branch        'release'
  instance_type 'm3.large'
  rails_env     'production'
else
  raise
end
title            ENV["APP_NAME"]
service_role_arn "arn:aws:iam::139228664779:role/aws-opsworks-service-role"
default_instance_profile_arn "arn:aws:iam::139228664779:instance-profile/aws-opsworks-ec2-role"
chef_version     '11.10'
ruby_version     '2.2.0'
rubygems_version '2.1.5'
bundler_version  '1.3.5'
rails_stack      'nginx_unicorn'
ssh_key          ENV["STACK_NAME"]
repository       ENV["REPOSITORY"]
deploy_key_local_path "#{ENV['HOME']}/.ssh/#{ENV["STACK_NAME"]}_deploy_rsa" # rake を実行する端末に鍵を置いてください
memcache_instance_type 'cache.m3.xlarge'
