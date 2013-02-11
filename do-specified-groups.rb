
$LOAD_PATH << '.'
require 'mooc'
require 'pp'

total_groups = []
disregarded = []

User.all(:group_code.not => '').map{|u| u.group_code.downcase.strip}.uniq.each do |group_code|
  original_user = User.first(:id => group_code)
  other_users = User.all(:conditions => ["trim(lower(group_code)) = ?", group_code.downcase.strip])
  users_to_group = []
  users_to_group << original_user if original_user
  users_to_group += other_users
  if users_to_group.size >= 4
    total_groups << users_to_group
  else
    # puts "Group code #{group_code} only has #{users_to_group.size} members. Disregarding for now."
    disregarded += users_to_group
  end
end

total = total_groups.reduce(0){|sum, g| sum += g.size}
puts "Total users in distinct specified groups #{total}"
puts "Total users disregarded b/c of small group size #{disregarded.size}"
total_groups.each_with_index do |group, index|
  puts "Group #{index + 1} with #{group.size} members"
  group.each do |user|
    puts "  => #{user.email} - #{user.group_code}"
  end
  g = Group.new
  g.users = group
  g.friend_based = true
  g.timezone = "Distinct Specified Group"
  g.save
end
  

  
# Total users in distinct specified groups 2422
# Total users disregarded b/c of small group size 2813
