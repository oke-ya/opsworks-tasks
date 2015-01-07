case ENV['RAILS_ENV']
when 'staging'
  instance_id      "#{ENV["STACK_NAME"]}-stg"
  instance_class   'db.t2.micro'
  multi_az         false
  storage_gigabyte '8'
when 'production'
  instance_id    ENV["STACK_NAME"]
  instance_class 'db.m3.xlarge'
  multi_az       true
  storage_gigabyte '100'
else
  raise
end
subnet_group_name ENV["SUBNET"]
dbms              'postgres'
dbms_version      '9.3.5'

