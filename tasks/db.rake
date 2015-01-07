namespace :db do
  task :alter_default_charset => [:environment, :load_config] do
    config = ActiveRecord::Base.connection_config
    ActiveRecord::Base.connection.execute("alter database #{config[:database]} default character set #{config[:encoding]};")
  end
end
