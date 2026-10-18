# Step 4: 直近7日間ランキング（Top 10）の集計時間とメモリ使用量を Ruby Hash と Valkey で比べる
# 実行: bin/rails runner script/step4_benchmark.rb
# 結果: results/step4_ranking.csv
require "csv"
require "objspace"

SIZES = [ 1_000, 10_000, 100_000 ] # 記事数
WARMUP = 3
RUNS = 11 # 奇数にして中央値をそのまま取る
DATES = (0...7).map { |i| (Date.new(2026, 10, 17) - i).strftime("%Y%m%d") }
KEYS = DATES.map { |date| "daily:#{date}" }

# Step 3 と同じ作り方のテストデータ: 日付ごとの { 記事ID => その日のPV数 }
def build_daily(articles)
  rng = Random.new(42)
  DATES.to_h do |date|
    views = (1..articles).to_h { |i| [ "article-#{i}", rng.rand(0..20) ] }
    [ date, views.reject { |_, v| v.zero? } ]
  end
end

def ruby_totals(daily)
  totals = Hash.new(0)
  daily.each_value { |views| views.each { |article, v| totals[article] += v } }
  totals
end

def ruby_top10(daily)
  ruby_totals(daily).sort_by { |article, score| [ score, article ] }.reverse.first(10)
end

def valkey_top10
  VALKEY.zunionstore("dest", KEYS)
  VALKEY.zrange("dest", 0, 9, rev: true, with_scores: true).map { |article, score| [ article, score.to_i ] }
end

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

# Ruby のメモリ: Hash 本体 + キーの文字列（PV数の小さな Integer は Hash の中に直接入るので 0）
def ruby_bytes(hash)
  ObjectSpace.memsize_of(hash) + hash.keys.sum { |key| ObjectSpace.memsize_of(key) }
end

# Valkey のメモリ: MEMORY USAGE（SAMPLES 0 で全要素を数える）
def valkey_bytes(key)
  VALKEY.call("MEMORY", "USAGE", key, "SAMPLES", "0")
end

valkey_version = VALKEY.info("server")["valkey_version"]
puts "Ruby #{RUBY_VERSION} / Valkey #{valkey_version}"

rows = SIZES.flat_map do |articles|
  daily = build_daily(articles)

  # データ投入（Valkey のみ。Ruby 版はデータがすでにメモリ上にある前提）
  VALKEY.del(*KEYS, "dest")
  load_ms = elapsed_ms { daily.each { |date, views| VALKEY.zadd("daily:#{date}", views.map { |a, v| [ v, a ] }) } }.round(3)

  raise "Top 10 が一致しません (#{articles})" unless ruby_top10(daily) == valkey_top10

  ruby_time = measure { ruby_top10(daily) }
  valkey_time = measure { valkey_top10 }

  # data_bytes: 7日分の日次データ / result_bytes: 集計結果を持つための追加メモリ
  # （Ruby の totals のキーは日次データの文字列を共有するので Hash 本体のみ数える）
  ruby_data = daily.values.sum { |views| ruby_bytes(views) }
  ruby_result = ObjectSpace.memsize_of(ruby_totals(daily))
  valkey_data = KEYS.sum { |key| valkey_bytes(key) }
  valkey_result = valkey_bytes("dest")

  puts format("%7d articles | Ruby %9.3f ms | Valkey %9.3f ms (load %9.3f ms)", articles, ruby_time[0], valkey_time[0], load_ms)

  [
    [ articles, "ruby", nil, *ruby_time, ruby_data, ruby_result, RUBY_VERSION, valkey_version ],
    [ articles, "valkey", load_ms, *valkey_time, valkey_data, valkey_result, RUBY_VERSION, valkey_version ]
  ]
end

FileUtils.mkdir_p("results")
CSV.open("results/step4_ranking.csv", "w") do |csv|
  csv << %w[articles impl load_ms agg_median_ms agg_min_ms agg_max_ms data_bytes result_bytes ruby_version valkey_version]
  rows.each { |row| csv << row }
end
puts "saved: results/step4_ranking.csv"
