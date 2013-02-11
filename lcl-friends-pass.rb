require 'rest_client'
require 'json'
$LOAD_PATH << '.'
require 'mooc'
require 'pp'
require 'logger'
require 'ruby-debug'


# ENV['MAILGUN_API_KEY'] = "key-4kkoysznhb93d1hn8r37s661fgrud-66"
RestClient.log = 'restclient.log'


module UserGroupMethods
  def grouped_users
    @groups.flatten
  end

  def ungrouped_users
    @users - grouped_users
  end

  def shuffle_users!
    # shuffle the deck of users 7 times. Poker pays off
    7.times{ @users.shuffle! }
  end
end

class MatchGroup < Array
  attr_accessor :properties

  def initialize(props = {})
    @properties = props
    super()
  end

  def most_frequent(name)
    r = group_by{|g| g.send(name) }.max_by{|i, o| o.size}
    r ? r.flatten.last.send(name) : ''
  end

  def add_user(user, run_hook = true)
    push(user)
  end

  def method_missing(method, *args)
    most_frequent(method)
  end

  def inspect
    @properties.inspect + super
  end

end



class MatchingStrategy
  include UserGroupMethods

  def name
    self.class.to_s
  end

  def setup(logger, users, groups)
    @log = logger
    @users = users
    @groups = groups
    @group_codes = User.all(:group_code.not => '', :group_id => nil, :source => 'main').map{|u| u.group_code.downcase.strip}.uniq
  end

  def run_all
    run_before_match
    run_match
    run_after_match
  end

  def users_specified_group(user)
    group_code = user.group_code && user.group_code.downcase.strip
    if group_code && @group_codes.include?(group_code)
      puts "#{user.email} (#{user.id}) has group code #{group_code}"      
      group = @groups.select{|g| g.any?{|u| u.group_code && (u.group_code.downcase.strip == group_code)}}.first
      if group
        gcs = group.map{|g| g.group_code}.join(", ")
        puts "    --- found a group with #{gcs}"
        return group
      else
        group = @groups.select{|g| g.any?{|u| u.id && (u.id.to_i == group_code.to_i)}}.first
        if group
          gids = group.map{|g| g.id}.join(", ")
          puts "   --- found an id match in #{gids}"
          return group
        else
          return nil
        end
      end
    else
      gr = @groups.select{|g| g.any?{|u| u.group_code && (u.group_code.downcase.strip.to_s == user.id.to_s.downcase.strip)}}.first
      if gr
        puts "   --- found an inverse id match in #{user.id}"      
        return gr
      else
        return nil
      end
    end
  end

  def add_user_to_group(user, group)
    if usg = users_specified_group(user)
      puts "   ==> Adding #{user.email} to same group"
      usg.add_user(user)
    else
      group.add_user(user)
    end
  end

  def run_match
    return @log.debug "'match' not implemented for #{name}" unless respond_to? :match
    @users.each do |user|
      @groups.shuffle!
      @log.debug "Matching #{user.inspect} using #{name}"
      group = match(user, @groups)
      if group
        @log.debug "Matched to group: #{group.inspect}"
        add_user_to_group(user, group)
        @groups << group unless @groups.include? group
        @log.debug "Number of available groups: #{@groups.size}"
      else
        @log.debug "Could not find a group for user: #{user.inspect}"
      end
    end
  end

  def run_before_match
    return @log.debug "'before_match' not implemented for #{name}" unless respond_to? :before_match
    before_match(@users, @groups)
  end

  def run_after_match
    return @log.debug "'after_match' not implemented for #{name}" unless respond_to? :after_match
    after_match(@users, @groups)
  end

  private

  attr_accessor :users, :groups

end



class SpecificStrategy < MatchingStrategy
  attr_accessor :rules, :create_group_on_not_found, :respect_target_sizes, :amount_allowed_over_target

  def initialize
    @rules = []
    @create_group_on_not_found = false
    @respect_target_sizes = true
    @amount_allowed_over_target = 0
  end

  def add_rule( &block )
    @rules << block
  end

  def match(user, groups)
    groups.each do |group|
      if @respect_target_sizes
        if group.size < (group.properties[:target_size].to_i + @amount_allowed_over_target)
          return group if @rules.any?{|r| r.call(user, group) }
        end
      end
    end
    @create_group_on_not_found ? MatchGroup.new : false
  end
end

class MakeGroupStrategy < MatchingStrategy
  attr_accessor :groups_to_make, :min_group_size, :user_criteria

  def initialize
    @groups_to_make = {}
    @user_criteria = []
  end

  def before_match(users, groups)
    @groups_to_make.each do |size, number_of_that_size|
      number_of_that_size.to_i.times do
        groups << MatchGroup.new(:target_size => size)
      end
    end
    puts groups.inspect
  end
end

class DistributeInitialStrategy < MatchingStrategy
  attr_accessor :criteria

  def before_match(users, groups)
    return unless @criteria
    criteria_freqs = users.group_by{|u| u.send(@criteria)}.map do |criteria, users|
      {users.size => users}
    end
    criteria_freqs = criteria_freqs.sort_by{|h| h.keys.first}.reverse
    level = 0
    #    puts ":::::::::::::::::" + criteria_freqs.inspect
    while groups.any?{|g| g.size == 0}
      criteria_freqs.each do |cf|
        group = groups.select{|g| g.size == 0}.sample
        #        puts cf.values.first.size
        user = cf.values.first.pop
        #        puts cf.values.first.size
        next unless user && group
        puts "Adding #{user.email} to group in timezone #{user.timezone}"
        add_user_to_group(user, group)
      end
      level += 1
    end
  end
end

class FoldSmallGroupStrategy < MatchingStrategy
  attr_accessor :hard_minimum, :relative_minimum

  def before_match(users, groups)
    groups.map do |group|
      if (@hard_minimum && (group.size < @hard_minimum)) ||
          (@relative_minimum && group.size < group.properties[:target_size].to_i - @relative_minimum )
        group.clear
      else
        group
      end
    end
  end
end

class MakeSpecificGroupStrategy < MatchingStrategy
  attr_accessor :groups_to_make

  def initialize
    @groups_to_make = []
  end

  def create_group(props)
    @groups_to_make << MatchGroup.new(props)
  end

  def before_match(users, groups)
    @groups_to_make.each do |g|
      groups << g
      @log.debug "Created group: #{g.inspect}"
    end
  end

end


class Classifier
  include UserGroupMethods
  attr_accessor :logger, :users, :groups
  attr_reader :matching_strategies, :groups

  def initialize(*matching_strategies)
    @matching_strategies = matching_strategies
    @users = []
    @groups = []
    init_logger
    @log.info "Setup classifier using: #{@matching_strategies.inspect}"
  end

  def init_logger
    @logger = Logger.new(STDOUT)
    @logger.level = Logger::DEBUG
    @log = @logger
  end

  def classify!
    @log.info "Started classifying"
    @matching_strategies.each do |ms|
      shuffle_users!
      run(ms)
    end
    @log.debug "Results: "
    @log.debug @groups.inspect
    @log.warn "There are #{ungrouped_users.size} users that were not grouped"
    @log.warn "They are: \n #{ungrouped_users.inspect}"
  end

  def run(matching_strategy)
    return @log.error "#{ms} is not a valid MatchingStrategy" unless matching_strategy.is_a? MatchingStrategy
    @log.info "Running Matching Strategy: #{matching_strategy.name}"
    matching_strategy.setup(@logger, ungrouped_users, @groups)
    matching_strategy.run_all
    # run_before_match(matching_strategy)
    # run_match(matching_strategy)
    # run_after_match(matching_strategy)
  end

  def results_to_db!
    @groups.each do |group|
      dm_group = Group.new
      dm_group.users = group
      dm_group.timezone = "Friends - #{group.timezone}"
      dm_group.save
    end
  end

  def prompt_for_save_to_db!
    puts "Would you like to use these groups? (type 'yes' to save)"
    answer = gets.chomp
    if answer == 'yes'
      results_to_db!
    end
  end

  def results_to_file(file_name)
    open(file_name, 'w') do |file|
      file.puts "Total Groups: " + @groups.size.to_s
      @groups.uniq(&:size).each do |group|
        file.puts "\tGroups with " + group.size.to_s + " members: " +
          @groups.select{|g| g.size == group.size}.size.to_s
      end
      file.puts "Unique Emails " + grouped_users.collect(&:email).uniq.count.to_s
      file.puts "Total Users to Group: " + @users.size.to_s
      file.puts "Total Grouped Users: " + grouped_users.size.to_s
      file.puts "Unique Timezone Groups: " + @groups.collect(&:timezone).uniq.count.to_s
      file.puts "Unique Timezone Users: " + @groups.collect(&:timezone).uniq.count.to_s
      @groups.each_with_index do |group, index|
        file.puts "\nGroup " + (index + 1).to_s
        file.puts "\tTarget Size: " + group.properties[:target_size]
        file.puts "\tCurrent Size: " + group.size.to_s
        file.puts "\tTimezone: " + group.timezone
        file.puts "\tUsers:"
        group.each do |user|
          file.puts "\t\tUser " + user.id.to_s + ": \t\t" +
            [user.email, user.timezone, user.source, user.group_code].join(", ")
        end
      end
    end
  end

end






mgs = MakeGroupStrategy.new
mgs.groups_to_make = {'20' => 118 }

dis = DistributeInitialStrategy.new
dis.criteria = :timezone

# frgs = FillRequestedGroupsStrategy.new

sms = SpecificStrategy.new
sms.add_rule {|u, g| u.timezone == g.timezone }

sms2 = SpecificStrategy.new
sms2.add_rule {|u, g| u.timezone.split('/').first == g.timezone.split('/').first}
sms2.add_rule {|u, g| u.timezone.split('/').first == 'Pacific' && g.timezone.split('/').first == 'Asia'}
sms2.add_rule {|u, g| u.timezone.split('/').first == 'Africa' && g.timezone.split('/').first == 'Europe'}
sms2.add_rule {|u, g| u.timezone.split('/').first == 'Etc' && g.timezone.split('/').first == 'Asia'}

sms_over2 = SpecificStrategy.new
sms_over2.amount_allowed_over_target = 1
sms_over2.add_rule {|u, g| u.timezone.split('/').first == g.timezone.split('/').first}
sms_over2.add_rule {|u, g| u.timezone.split('/').first == 'Pacific' && g.timezone.split('/').first == 'Asia'}
sms_over2.add_rule {|u, g| u.timezone.split('/').first == 'Africa' && g.timezone.split('/').first == 'Europe'}
sms_over2.add_rule {|u, g| u.timezone.split('/').first == 'Etc' && g.timezone.split('/').first == 'Asia'}


fsgs = FoldSmallGroupStrategy.new
fsgs.hard_minimum = 14

all = SpecificStrategy.new
all.add_rule {|u, g| true }

c = Classifier.new(mgs, dis, sms, sms2, dis, sms, sms2,
                   fsgs, dis, sms, sms2, sms2,
                   fsgs, dis, sms, sms2, sms2,
                   fsgs, dis, sms, sms2, sms2, fsgs, all)
c.logger.level = Logger::INFO
c.users = User.all( :source => 'main', :group_id => nil, :defered.not => "no")



c.classify!
c.results_to_file('groups-friends.log')
c.prompt_for_save_to_db!


#    original_user = User.first(:id => group_code, :id.not => user.id, :group_id => nil, :source => "main", :defered.not => "no")
#    other_users = User.all(:conditions => ["trim(lower(group_code)) = ? AND id != ? AND source = ? AND defered != ?", group_code, user.id, "main", "no"])
#    users_to_group = []
#    users_to_group << original_user if original_user
#    users_to_group += other_users
#    users_to_group.uniq.each do |ou|
#      puts ou.inspect
#      unless group.map{|u| u.email}.include? ou.email
#        puts "  => Adding #{ou.email} to the same group as #{user.email}"
#        group.add_user(ou, false)
#      end
#    end
