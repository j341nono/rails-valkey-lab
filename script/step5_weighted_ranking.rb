# Step 5: WEIGHTS による時間減衰ランキング（講演資料 p.30）を Ruby Hash と Valkey で比べる
# 実行: bin/rails runner script/step5_weighted_ranking.rb
# 結果: results/step5_weighted_ranking.csv
require "csv"
require "objspace"

SIZES = [ 1_000, 10_000, 100_000 ] # 記事数
WARMUP = 3
RUNS = 11
DATES = (0...7).map { |i| (Date.new(2026, 10, 17) - i).strftime("%Y%m%d") } # 新しい日付から順
KEYS = DATES.map { |date| "daily:#{date}" }
RANKINGS = {
  "simple" => [ 1 ] * 7, # 重みなし（Step 4 と同じ単純合計）
  # p.30 の重み（1.0, 0.9, 0.81, ...）を100倍した整数。KEYS と同じ順（新しい日ほど重い）
  # 小数のままだと、Ruby と Valkey で足す順番が違うため最後の桁がずれる（Valkey は要素数の少ないキーから足す）。
  # 整数なら誤差が出ず、全体を100倍しても順位は変わらない
  "weighted" => [ 100, 90, 81, 73, 66, 59, 53 ]
}

# Step 3, 4 と同じ作り方のテストデータ: 日付ごとの { 記事ID => その日のPV数 }
def build_daily(articles)
  rng = Random.new(42)
  DATES.to_h do |date|
    views = (1..articles).to_h { |i| [ "article-#{i}", rng.rand(0..20) ] }
    [ date, views.reject { |_, v| v.zero? } ]
  end
end

# 日ごとに PV数 × 重み を足す。Valkey と同じく新しい日付から順に足す
def ruby_totals(daily, weights)
  totals = Hash.new(0)
  daily.values.zip(weights).each do |views, weight|
    views.each { |article, v| totals[article] += v * weight }
  end
  totals
end

def ruby_ranking(daily, weights)
  ruby_totals(daily, weights).sort_by { |article, score| [ score, article ] }.reverse
end

# stop: 取り出す最後の順位（0始まり。-1 なら全件）
def valkey_ranking(weights, stop)
  VALKEY.zunionstore("dest", KEYS, weights: weights)
  VALKEY.zrange("dest", 0, stop, rev: true, with_scores: true)
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

valkey_version = VALKEY.info("server")["valkey_version"]
puts "Ruby #{RUBY_VERSION} / Valkey #{valkey_version}"

rows = SIZES.flat_map do |articles|
  daily = build_daily(articles)
  VALKEY.del(*KEYS, "dest")
  daily.each { |date, views| VALKEY.zadd("daily:#{date}", views.map { |a, v| [ v, a ] }) }

  simple_top10 = ruby_ranking(daily, RANKINGS["simple"]).first(10).map(&:first)
  weighted_top10 = ruby_ranking(daily, RANKINGS["weighted"]).first(10).map(&:first)
  puts "#{articles} articles: 全順位一致 / Top 10 のうち重みで入れ替わった記事 #{(weighted_top10 - simple_top10).size} 件"

  RANKINGS.flat_map do |name, weights|
    # 正しさ: 全順位とスコアが完全に一致するか
    raise "#{name} が一致しません (#{articles})" unless ruby_ranking(daily, weights) == valkey_ranking(weights, -1)

    ruby_time = measure { ruby_ranking(daily, weights).first(10) }
    valkey_time = measure { valkey_ranking(weights, 9) }
    # result_bytes: 集計結果を持つための追加メモリ（日次データのメモリは Step 4 と同じなので省略）
    ruby_result = ObjectSpace.memsize_of(ruby_totals(daily, weights))
    valkey_result = VALKEY.call("MEMORY", "USAGE", "dest", "SAMPLES", "0")
    puts format("  %-8s | Ruby %9.3f ms | Valkey %9.3f ms", name, ruby_time[0], valkey_time[0])

    [
      [ articles, name, "ruby", *ruby_time, ruby_result, RUBY_VERSION, valkey_version ],
      [ articles, name, "valkey", *valkey_time, valkey_result, RUBY_VERSION, valkey_version ]
    ]
  end
end

FileUtils.mkdir_p("results")
CSV.open("results/step5_weighted_ranking.csv", "w") do |csv|
  csv << %w[articles ranking impl agg_median_ms agg_min_ms agg_max_ms result_bytes ruby_version valkey_version]
  rows.each { |row| csv << row }
end
puts "saved: results/step5_weighted_ranking.csv"
