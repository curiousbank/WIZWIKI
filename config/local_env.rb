# Loads local secrets before environment configuration reads ENV.
# Keep .env.local untracked; production should use real process environment.
local_env_path = File.expand_path("../.env.local", __dir__)

if File.exist?(local_env_path)
  File.foreach(local_env_path) do |line|
    next if line.strip.empty? || line.lstrip.start_with?("#")

    key, value = line.split("=", 2)
    next if key.nil? || key.strip.empty? || value.nil?

    ENV[key.strip] ||= value.strip.gsub(/\A['"]|['"]\z/, "")
  end
end
