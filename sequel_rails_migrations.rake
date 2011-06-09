require "sequel"
require "sequel/extensions/migration"

# This is a simple adapter to use Sequel's migrations in a Rails
# 2.3-based environment.  Rails 3 users should look elsewhere.
# It is different from existing adapters in that it uses the same
# rake target names that Rails does for the same functions.
#
# To install in your Rails 2.3-based project, copy this file
# into lib/tasks.  Rails will then include it automatically.
#
# Some limitations and assumptions:
#   * Uses timestamp migrations (like Rails 2.3)
#
#   * There are likely to be previous non-Sequel migrations.
#     They should be run first, and then the Sequel migrations
#     run afterward.
#
#   * You won't be adding more ActiveRecord migrations, so
#     the two types of migrations will never be interleaved.
#
# Some code is adapted from Rails 2.3.5's lib/tasks/databases.rake

# TODO(noah): Make "up" and "down" only go those directions
# TODO(noah): Make STEP work in number of migrations, not just subtract

Rake::TaskManager.class_eval do
  def remove_task(task_name)
    @tasks.delete(task_name.to_s)
  end
end

# Remove the Rails tasks we're overriding
Rake.application.remove_task("db:migrate")
Rake.application.remove_task("db:migrate:up")
Rake.application.remove_task("db:migrate:down")
Rake.application.remove_task("db:rollback")
Rake.application.remove_task("db:version")
Rake.application.remove_task("db:abort_if_pending_migrations")

# Override the rails "db:migrate" task to use our Sequel migrations.
namespace :db do
  task :sequel_open do
    DB = set_up_db_connection(RAILS_ENV || "development")
  end

  desc "Run the Sequel database migrations"
  task :migrate => [:sequel_open, :environment] do
    environment = RAILS_ENV || "development"

    return if environment == "test"

    if is_still_using_rails_migrations_table?(environment)
      puts "Running all outstanding Rails migrations prior to switching over permanently to the " +
          "Sequel-based migrations."
      Rake::Task["db:rails_migrate"].invoke
      rename_rails_schema_migrations_table(environment)
    end

    run_sequel_migration(environment)
  end

  desc "Run the old rails migrations"
  task :rails_migrate => :environment do
    # Copied from database.rake from the Rails 2.3.5 gem.
    ActiveRecord::Migration.verbose = ENV["VERBOSE"] ? ENV["VERBOSE"] == "true" : true
    ActiveRecord::Migrator.migrate("db/migrate/", ENV["VERSION"] ? ENV["VERSION"].to_i : nil)
    Rake::Task["db:schema:dump"].invoke if ActiveRecord::Base.schema_format == :ruby
  end

  task :abort_if_pending_migrations => :sequel_open do
    # Sequel::Migrator doesn't have any easy way to find this out, but you *can* get
    # the list of migration files and the current version.
    migrator = new_migrator DB

    pending_migrations = migrator.files.map {|path| File.basename(path).downcase} - migrator.applied_migrations

    # This format is chosen to match Rails 2.3 output
    if pending_migrations.any?
      puts "You have #{pending_migrations.size} pending migrations:"
      pending_migrations.each do |filename|
        filename =~ /([0-9]+)_(.*)/
        version = ($~[1]).to_i
        name = $~[2]
        puts '  %4d %s' % [version, name]  # Display version and name
      end
      abort %{Run "rake db:migrate" to update your database then try again.}
    end
  end

  # ActiveRecord distinguishes between up and down.  For now, we'll just migrate to whatever version
  # you say and trust you that it's up or down.
  namespace :migrate do
    task :up => :sequel_open do
      environment = RAILS_ENV || "development"
      return if environment == "test"

      version = ENV["VERSION"] ? ENV["VERSION"].to_i : nil
      raise "VERSION is required" unless version
      run_sequel_migration(environment, :to => version)
    end

    task :down => :sequel_open do
      environment = RAILS_ENV || "development"
      return if environment == "test"

      version = ENV["VERSION"] ? ENV["VERSION"].to_i : nil
      raise "VERSION is required" unless version
      run_sequel_migration(environment, :to => version)
    end
  end

  task :rollback => :sequel_open do
    environment = RAILS_ENV || "development"
    return if environment == "test"
    step = ENV['STEP'] ? ENV['STEP'].to_i : 1

    migrator = new_migrator DB, :target => current_migration_version(DB) - step
    puts "Running rollback migrator to version #{migrator.target}"
    migrator.run
  end

  task :version => :sequel_open do
    puts "Current version: #{current_migration_version(DB)}"
  end
end

def database_yml
  @database_yml ||= YAML.load(File.read(File.join(File.dirname(__FILE__), "..", "..", "config", "database.yml")))
end

def db_migrations
  File.join(File.dirname(__FILE__), "..", "..", "db_migrations")
end

def new_migrator(db, options = {})
  @migrators ||= {}
  @migrator_options ||= {}
  if(@migrators[db] && @migrator_options[db] == options)
    return @migrators[db]
  end
  m = Sequel::Migrator.send(:migrator_class, db_migrations).new(db, db_migrations, options)
  @migrators[db] = m
  @migrator_options[db] = options
  raise "We only support TimestampMigrators right now!" unless m.kind_of?(Sequel::TimestampMigrator)
  m
end

def set_up_db_connection (environment)
  Sequel.connect(database_yml[environment])
end

def is_still_using_rails_migrations_table?(environment)
  DB.tables.include?(:schema_migrations) && DB[:schema_migrations].columns.include?(:version)
end

# Renames the Rails schema_migrations table to make way for the Sequel table of the same name.
# NOTE(philc): Sequel and Rails use the same table to store their schema migration information. I don't know
# how to configure Sequel to store its migrations into a different table, so for now I'm renaming the Rails
# table to make room for the Sequel table. The rails table has a "version" column, whereas the Sequel table
# has a "filename" column.
def rename_rails_schema_migrations_table(environment)
  return unless is_still_using_rails_migrations_table?(environment)
  db = Sequel.connect(database_yml[environment])
  db.rename_table(:schema_migrations, :rails_schema_migrations)
end

def run_sequel_migration(environment, options = {})
  options[:to] = ENV["VERSION"].to_i if ENV["VERSION"]

  # TODO(philc): Remove this debug output. This is to debug C3's CI problems.
  puts "Running sequel migrations for #{environment}"

  m = new_migrator DB, :target => options[:to], :current => options[:from]
  m.run
  #Rake::Task["db:schema:dump"].invoke if ActiveRecord::Base.schema_format == :ruby  # Dump the schema in Sequel?

  exit_status = $?.exitstatus
  raise "The DB migrations failed to run." unless (exit_status == 0)
end

def current_migration_version(db)
  migrator = new_migrator db

  # Sequel doesn't really have a "current migration version".  And for the
  # Timestamp Migrator, it's not entirely clear what one would look like.
  # So we hack it.

  applied_migrations = migrator.applied_migrations
  applied_migrations.max.to_i
end
