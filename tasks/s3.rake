aws_config = Rails.root.join('config', 'aws.rb')
require aws_config if File.exists?(aws_config)
require 'timeout'

namespace :s3 do
  task :initialize do
    ENV["APP_ENV"] = "prod"
    @opts = Configure.new('opsworks').parse
    @s3 = AWS::S3.new
  end

  namespace :bucket do
    task :create => [:"s3:initialize"] do
      name = @opts[:stack_name] + "-nginx-log"
      begin
        @bucket = @s3.buckets.create(name)
      rescue AWS::S3::Errors::BucketAlreadyOwnedByYou
        @bucket = @s3.buckets[name]
      end
    end
  end
end
