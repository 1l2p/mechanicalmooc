
require 'mooc'
require 'seq-email'
require 'digest/sha1'

ENV['MMOOC_CONFIRM_SALT'] ||= "lalalalala"

module UserDefer

  def self.send_to_all(users)
    users.each do |email|
      self.send_defer_email(email)      
    end
  end

  def self.send_defer_email(email)
    body = File.read('./emails/user-defer.html')
    
    link_yes_template = "http://3avf.localtunnel.com/defer?email=%EMAIL%&auth_token=%AUTH_TOKEN%&defer=yes"
    link_no_template = "http://3avf.localtunnel.com/defer?email=%EMAIL%&auth_token=%AUTH_TOKEN%&defer=no"
    yes_defer_link = link_yes_template.sub('%EMAIL%', email).sub('%AUTH_TOKEN%', email_auth(email))
    no_defer_link = link_no_template.sub('%EMAIL%', email).sub('%AUTH_TOKEN%', email_auth(email))

    body.sub!('%LINK_DEFER_YES%', yes_defer_link)
    body.sub!('%LINK_DEFER_NO%', no_defer_link)

    se = SequenceEmail.new
    se.subject = "Learning Creative Learning course about to take off - Please confirm your seat!"
    se.from = "The Machine (aka Oliver) <no-reply@p2pu.org>"
    se.body = body
    se.tags << "user-defer-email"
    se.send_email_to(email)
  end
  
  def self.defer(email, auth_token, defer)
    return false unless valid? email, auth_token
    user = User.last(:email => email)
    return false unless user
    # This is to prevent a hacked get request from being saved to our DB
    if defer == "yes"
      user.defered = "yes"
    elsif defer == "no"
      user.defered = "no"
    end
    user.save
  end

  def self.valid?(email, auth_token)
    email_auth(email) == auth_token
  end

  def self.email_auth(email)
    Digest::SHA1.hexdigest email + ENV['MMOOC_CONFIRM_SALT']
  end
end
