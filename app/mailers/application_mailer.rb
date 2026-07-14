class ApplicationMailer < ActionMailer::Base
  default from: -> { ENV["WIZWIKI_MAIL_FROM"].presence || "Thumper von AUTOS <no-reply@example.invalid>" }
  layout "mailer"
end
