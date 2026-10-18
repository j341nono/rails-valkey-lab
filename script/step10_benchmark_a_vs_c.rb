# Step 10: 方式A（PostgreSQL のみ）と方式C（PostgreSQL + Valkey）を比較測定する
# 実行: bin/rails runner script/step10_benchmark_a_vs_c.rb
#       件数を変える場合: EVENTS=300000,3000000 bin/rails runner script/step10_benchmark_a_vs_c.rb
# 結果: results/step10_ops.csv（書き込み・ランキング取得・再構築の時間）, results/step10_memory.csv
#       コンテナで遅延を入れる場合: docker compose run --rm -e NET_DELAY=1ms app bin/rails runner script/step10_benchmark_a_vs_c.rb
require "csv"

# NET_DELAY（コンテナ実行時のネットワーク遅延。例: 1ms）ごとに結果ファイルを分ける
SUFFIX = ENV["NET_DELAY"].present? ? "_delay#{ENV['NET_DELAY']}" : ""
EVENT_SIZES = ENV.fetch("EVENTS", "300000,3000000").split(",").map(&:to_i) # 30日間の総イベント数
ARTICLES = 10_000
TODAY = Date.current # 保持期間（EXPIREAT）が実時刻で判定されるため、今日を基準にする
FIRST_DAY = TODAY - (PageView::RETENTION_DAYS - 1)
BATCH = 10_000
WRITES = 1_000
WRITE_ARTICLE = ARTICLES + 1 # 書き込み測定用の記事。測定後に消す

ActiveRecord::Base.logger = nil                     # SQL ログの書き込み時間を測定に含めない
ActiveRecord::Base.connection.disable_query_cache!  # 毎回 DB で集計させる
DB = ActiveRecord::Base.connection

def elapsed_ms
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  yield
  (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000
end

# warmup 回空回ししてから runs 回測り、[中央値, p95, 最小, 最大] を返す
def measure(runs:, warmup:, gc: true, &block)
  warmup.times { block.call }
  times = Array.new(runs) { GC.start if gc; elapsed_ms(&block) }.sort
  [ times[runs / 2], times[(runs * 0.95).ceil - 1], times.first, times.last ].map { |t| t.round(3) }
end

# 1回の操作で Rails（Ruby）側が作るオブジェクト数
def allocated_objects
  before = GC.stat(:total_allocated_objects)
  yield
  GC.stat(:total_allocated_objects) - before
end

def valkey_bytes(pattern)
  VALKEY.scan_each(match: pattern).sum { |key| VALKEY.call("MEMORY", "USAGE", key, "SAMPLES", "0").to_i }
end

versions = [ RUBY_VERSION, DB.select_value("SHOW server_version")[/\S+/], VALKEY.info("server")["valkey_version"] ]
puts "Ruby #{versions[0]} / PostgreSQL #{versions[1]} / Valkey #{versions[2]}"
# 実際の往復時間。NET_DELAY の効き方は環境で異なるため、指定値ではなく実測値を記録する
rtt = ->(&b) { Array.new(200) { elapsed_ms(&b) }.sort[100].round(3) }
rtts = [ rtt.() { VALKEY.ping }, rtt.() { DB.select_value("SELECT 1") } ]
puts "往復時間（中央値）: Valkey #{rtts[0]} ms / PostgreSQL #{rtts[1]} ms"
ops = []
memory = []

EVENT_SIZES.each do |events|
  # --- 準備（測定対象外。一括投入の時間は参考値） ---
  DB.truncate("page_views")
  VALKEY.scan_each(match: "page_views:*") { |key| VALKEY.del(key) }
  rng = Random.new(42)
  start_at = FIRST_DAY.in_time_zone.to_i
  bulk_ms = (events / BATCH).times.sum do
    rows = Array.new(BATCH) { { article_id: rng.rand(1..ARTICLES), viewed_at: Time.at(start_at + rng.rand(PageView::RETENTION_DAYS * 86_400)).utc } }
    elapsed_ms { PageView.insert_all(rows) }
  end
  DB.execute("VACUUM ANALYZE page_views") # 統計情報を更新（実運用では autovacuum が行う）

  # --- 同期コスト①: PostgreSQL から Valkey の日別 Sorted Set を作り直す（C の準備も兼ねる） ---
  rebuild = measure(runs: 3, warmup: 0) { PageView.rebuild_valkey(from: FIRST_DAY, to: TODAY) }
  ops << [ events, "C", "rebuild_valkey", *rebuild, allocated_objects { PageView.rebuild_valkey(from: FIRST_DAY, to: TODAY) } ]

  # --- 正しさ: A と C の全順位が一致するか ---
  [ false, true ].each do |weighted|
    a = PageView.top_from_postgresql(today: TODAY, limit: nil, weighted:)
    raise "不一致 (#{events}, weighted=#{weighted})" unless a == PageView.top_from_valkey(today: TODAY, limit: nil, weighted:)
  end

  # --- ランキング取得（Top 10） ---
  { "A" => :top_from_postgresql, "C" => :top_from_valkey }.each do |method, finder|
    [ false, true ].each do |weighted|
      call = -> { PageView.public_send(finder, today: TODAY, weighted:) }
      ops << [ events, method, weighted ? "ranking_weighted" : "ranking", *measure(runs: 11, warmup: 3, &call), allocated_objects(&call) ]
    end
  end

  # --- メモリ（ランキング取得後なので Valkey の集計結果キーも含む） ---
  table, index = DB.select_rows("SELECT pg_table_size('page_views'), pg_indexes_size('page_views')").first
  memory << [ events, "postgresql", "page_views（A・C 共通）", table, index ]
  memory << [ events, "valkey", "日別キー（C のみ）", valkey_bytes("page_views:daily:*"), nil ]
  memory << [ events, "valkey", "集計結果キー（C のみ）", valkey_bytes("page_views:top:*"), nil ]
  # Rails プロセスの RSS（データ準備の一括投入を含むので、A・C の差ではなく参考値）。Linux はピーク値、macOS は現在値
  rss_kb = File.exist?("/proc/self/status") ? File.read("/proc/self/status")[/VmHWM:\s+(\d+)/, 1].to_i : `ps -o rss= -p #{Process.pid}`.to_i
  memory << [ events, "rails", "プロセスの RSS（参考）", rss_kb * 1024, nil ]

  # --- 書き込み（1件ずつ create!）。A は Valkey 同期なし、C は after_create_commit で ZINCRBY ---
  { "A" => false, "C" => true }.each do |method, sync|
    PageView.sync_valkey = sync
    write = -> { PageView.create!(article_id: WRITE_ARTICLE, viewed_at: Time.current) }
    ops << [ events, method, "write", *measure(runs: WRITES, warmup: 50, gc: false, &write), allocated_objects(&write) ]
  end
  # C で増える分だけ（after_create_commit で実行する ZINCRBY + EXPIREAT の1往復）を単独で測る
  increment = -> { PageView.new(article_id: WRITE_ARTICLE, viewed_at: Time.current).send(:increment_daily_ranking) }
  ops << [ events, "C", "valkey_increment_only", *measure(runs: WRITES, warmup: 50, gc: false, &increment), allocated_objects(&increment) ]
  PageView.sync_valkey = true
  PageView.where(article_id: WRITE_ARTICLE).delete_all
  VALKEY.zrem(PageView.daily_key(TODAY), WRITE_ARTICLE)

  puts "#{events} events（一括投入 #{(bulk_ms / 1000).round(1)} s・参考値）"
  ops.select { |r| r[0] == events }.each { |r| puts format("  %s %-17s median %9.3f ms  p95 %9.3f ms", r[1], r[2], r[3], r[4]) }
  memory.select { |r| r[0] == events }.each { |r| puts format("  %-10s %-24s %8.1f MB%s", r[1], r[2], r[3] / 1e6, r[4] ? format(" + index %.1f MB", r[4] / 1e6) : "") }
end

FileUtils.mkdir_p("results")
CSV.open("results/step10_ops#{SUFFIX}.csv", "w") do |csv|
  csv << %w[events method operation median_ms p95_ms min_ms max_ms rails_allocated_objects valkey_rtt_ms pg_rtt_ms ruby_version pg_version valkey_version]
  ops.each { |row| csv << row + rtts + versions }
end
CSV.open("results/step10_memory#{SUFFIX}.csv", "w") do |csv|
  csv << %w[events store target data_bytes index_bytes valkey_rtt_ms pg_rtt_ms ruby_version pg_version valkey_version]
  memory.each { |row| csv << row + rtts + versions }
end
puts "saved: results/step10_*#{SUFFIX}.csv（NET_DELAY=#{ENV["NET_DELAY"].presence || "なし"}）"

# CPU 上限（compose.yaml の cpus）による待ちが起きていないか（cgroup v2。コンテナで実行したときだけ表示）
if File.exist?("/sys/fs/cgroup/cpu.stat")
  stat = File.read("/sys/fs/cgroup/cpu.stat").lines.to_h { |l| l.split.then { |k, v| [ k, v.to_i ] } }
  puts "app コンテナの CPU スロットリング: nr_periods=#{stat['nr_periods']} nr_throttled=#{stat['nr_throttled']} throttled_usec=#{stat['throttled_usec']}"
end
