# Valkey への接続。Rails 起動時に1回だけ作られ、どこからでも VALKEY で使える
VALKEY = Redis.new(url: ENV.fetch("VALKEY_URL", "redis://localhost:6380/0"))
