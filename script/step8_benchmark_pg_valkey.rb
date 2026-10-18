# Step 8: 直近7日間ランキングの投入時間・集計時間・メモリ使用量を PostgreSQL と Valkey で比べる
# 実行: bin/rails runner script/step8_benchmark_pg_valkey.rb
#       件数を変える場合: EVENTS=300000,3000000 bin/rails runner script/step8_benchmark_pg_valkey.rb
# 結果: results/step8_load.csv, results/step8_aggregate.csv
#
# 注意: PostgreSQL は生の閲覧イベント、Valkey は日別に事前集計した Sorted Set を持つ。
#       DB 単体の性能比較ではなく、実装方式全体の比較である。
require "csv"

EVENT_SIZES = ENV.fetch("EVENTS", "300000,3000000").split(",").map(&:to_i) # 30日間の総イベント数
ARTICLES = 10_000
DAYS = 30 # 保持期間。このうち直近7日を集計する
TODAY = Date.new(2026, 10, 17)
FIRST_DAY = TODAY - (DAYS - 1)
DATES = (0...7).map { |i| TODAY - i } # 集計対象（新しい日付から順）
WEIGHTS = [ 100, 90, 81, 73, 66, 59, 53 ] # p.30 の重みを100倍した整数（Step 5 参照）
BATCH = 10_000
WARMUP = 3
RUNS = 11
SINGLE_WRITES = 1_000

daily_key = ->(date) { "daily:#{date.strftime('%Y%m%d')}" }
ALL_KEYS = (0...DAYS).map { |i| daily_key.(FIRST_DAY + i) }
RANGE = DATES.last.in_time_zone...(TODAY + 1).in_time_zone # JST の 10/11 0:00 〜 10/18 0:00
COMPOSITE_INDEX = "index_page_views_on_viewed_at_and_article_id"

ActiveRecord::Base.logger = nil # SQL ログの書き込み時間を測定に含めない
DB = ActiveRecord::Base.connection

def elapsed_ms
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  yield
  (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000
end

# ウォームアップ後に RUNS 回測り、[中央値, 最小, 最大] を返す
def measure(&block)
  WARMUP.times(&block)
  times = Array.new(RUNS) { GC.start; elapsed_ms(&block) }.sort
  [ times[RUNS / 2], times.first, times.last ].map { |t| t.round(3) }
end

# 1回の集計で Rails（Ruby）側が作るオブジェクト数
def allocated_objects
  before = GC.stat(:total_allocated_objects)
  yield
  GC.stat(:total_allocated_objects) - before
end

# --- 集計処理（Step 7 と同じ。重み付きは JST の日付ごとに重みを掛けて合計する） ---
weight_sql = "CASE " + DATES.zip(WEIGHTS).map { |d, w| "WHEN viewed_at >= '#{d.in_time_zone.utc.strftime('%F %T')}' THEN #{w}" }.join(" ") + " END"

# rails runner では Active Record のクエリキャッシュが有効で、同じ SQL の2回目以降は DB に問い合わせない。
# 毎回 DB で集計させるため uncached で囲む
pg_ranking = lambda do |weighted, limit|
  PageView.uncached do
    scope = PageView.where(viewed_at: RANGE).group(:article_id).limit(limit)
    if weighted
      scope.order(Arel.sql("SUM(#{weight_sql}) DESC, article_id::text DESC")).sum(Arel.sql(weight_sql)).to_a
    else
      scope.order(Arel.sql("COUNT(*) DESC, article_id::text DESC")).count.to_a
    end
  end
end

valkey_ranking = lambda do |weighted, limit|
  VALKEY.zunionstore("dest", DATES.map(&daily_key), weights: weighted ? WEIGHTS : nil)
  VALKEY.zrange("dest", 0, (limit || 0) - 1, rev: true, with_scores: true).map { |a, s| [ a.to_i, s.to_i ] }
end

valkey_version = VALKEY.info("server")["valkey_version"]
pg_version = DB.select_value("SHOW server_version")
puts "Ruby #{RUBY_VERSION} / PostgreSQL #{pg_version} / Valkey #{valkey_version}"

load_rows = []
aggregate_rows = []

EVENT_SIZES.each do |events|
  # --- データ投入（同じイベントを両方へ。生成時間は含めない） ---
  DB.truncate("page_views")
  DB.remove_index(:page_views, name: COMPOSITE_INDEX) if DB.index_name_exists?(:page_views, COMPOSITE_INDEX)
  VALKEY.del(*ALL_KEYS, "dest")

  rng = Random.new(42)
  start_at = FIRST_DAY.in_time_zone.to_i # JST の 0:00（UNIX 秒）
  pg_load_ms = valkey_load_ms = 0.0
  (events / BATCH).times do
    batch = Array.new(BATCH) do
      t = start_at + rng.rand(DAYS * 86_400)
      [ rng.rand(1..ARTICLES), t ]
    end
    pg_load_ms += elapsed_ms { PageView.insert_all(batch.map { |a, t| { article_id: a, viewed_at: Time.at(t).utc } }) }
    valkey_load_ms += elapsed_ms do
      VALKEY.pipelined { |pipe| batch.each { |a, t| pipe.zincrby(ALL_KEYS[(t - start_at) / 86_400], 1, a) } }
    end
  end
  DB.execute("VACUUM ANALYZE page_views") # 統計情報を更新（実運用では autovacuum が行う）

  # --- 正しさ: 重みなし・重み付きの全順位が一致するか ---
  [ false, true ].each do |weighted|
    raise "不一致 (#{events}, weighted=#{weighted})" unless pg_ranking.(weighted, nil) == valkey_ranking.(weighted, nil)
  end

  # --- 集計時間（Top 10）。PostgreSQL は viewed_at のみ → 複合インデックス追加 の順に測る ---
  pg_variants = {
    "postgresql" => -> {},
    "postgresql_composite_index" => -> { DB.add_index(:page_views, [ :viewed_at, :article_id ], name: COMPOSITE_INDEX); DB.execute("VACUUM ANALYZE page_views") }
  }
  pg_sizes = {}
  pg_variants.each do |impl, setup|
    setup.call
    pg_sizes[impl] = DB.select_rows("SELECT pg_table_size('page_views'), pg_indexes_size('page_views')").first
    plan = DB.select_values("EXPLAIN #{PageView.where(viewed_at: RANGE).group(:article_id).select('article_id, COUNT(*)').to_sql}")
             .grep(/Scan/).first.to_s[/(Bitmap Heap|Index Only|Index|Seq) Scan/]
    [ false, true ].each do |weighted|
      time = measure { pg_ranking.(weighted, 10) }
      aggregate_rows << [ events, impl, weighted ? "weighted" : "simple", *time, allocated_objects { pg_ranking.(weighted, 10) }, plan ]
    end
  end
  [ false, true ].each do |weighted|
    time = measure { valkey_ranking.(weighted, 10) }
    aggregate_rows << [ events, "valkey", weighted ? "weighted" : "simple", *time, allocated_objects { valkey_ranking.(weighted, 10) }, nil ]
  end

  # --- 1件ずつの書き込み（実際のアプリで閲覧のたびに行う処理）。集計範囲外の 10/18 に書いて後で消す ---
  write_at = (TODAY + 1).in_time_zone + 12.hours
  write_key = daily_key.(TODAY + 1)
  pg_single = Array.new(SINGLE_WRITES) { elapsed_ms { PageView.create!(article_id: 1, viewed_at: write_at) } }.sort[SINGLE_WRITES / 2]
  valkey_single = Array.new(SINGLE_WRITES) { elapsed_ms { VALKEY.zincrby(write_key, 1, 1) } }.sort[SINGLE_WRITES / 2]
  PageView.where(viewed_at: write_at).delete_all
  VALKEY.del(write_key)

  # --- メモリ ---
  # PostgreSQL: テーブル・インデックスのサイズ（ディスク上。メモリに載るのはこのうちキャッシュされた部分）
  # Valkey: 30日分の日次キー + 集計結果 dest の MEMORY USAGE（メモリ上）
  valkey_data = ALL_KEYS.sum { |key| VALKEY.call("MEMORY", "USAGE", key, "SAMPLES", "0").to_i }
  valkey_dest = VALKEY.call("MEMORY", "USAGE", "dest", "SAMPLES", "0").to_i
  pg_sizes.each do |impl, (table, index)|
    load_rows << [ events, impl, pg_load_ms.round(1), pg_single.round(3), table, index ]
  end
  load_rows << [ events, "valkey", valkey_load_ms.round(1), valkey_single.round(3), valkey_data, valkey_dest ]

  puts "#{events} events: 投入 PostgreSQL #{pg_load_ms.round} ms / Valkey #{valkey_load_ms.round} ms"
  aggregate_rows.select { |r| r[0] == events }.each do |r|
    puts format("  %-27s %-8s %9.3f ms (%s)", r[1], r[2], r[3], r[7] || "-")
  end
end

DB.remove_index(:page_views, name: COMPOSITE_INDEX) if DB.index_name_exists?(:page_views, COMPOSITE_INDEX)

FileUtils.mkdir_p("results")
versions = [ RUBY_VERSION, pg_version, valkey_version ]
CSV.open("results/step8_load.csv", "w") do |csv|
  # data_bytes: PostgreSQL はテーブル、Valkey は30日分の日次キー
  # extra_bytes: PostgreSQL はインデックス、Valkey は集計結果 dest
  csv << %w[events impl bulk_load_ms single_write_median_ms data_bytes extra_bytes ruby_version pg_version valkey_version]
  load_rows.each { |row| csv << row + versions }
end
CSV.open("results/step8_aggregate.csv", "w") do |csv|
  csv << %w[events impl ranking agg_median_ms agg_min_ms agg_max_ms rails_allocated_objects pg_scan ruby_version pg_version valkey_version]
  aggregate_rows.each { |row| csv << row + versions }
end
puts "saved: results/step8_load.csv, results/step8_aggregate.csv"
