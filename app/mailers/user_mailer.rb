class UserMailer < ApplicationMailer
  def confirmation(user)
    @user = user
    mail subject: "Confirm your WIZWIKI account", to: user.email_address
  end
end
