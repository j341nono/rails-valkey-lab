# Step 3: 直近7日間ランキングを Ruby Hash と Valkey で作り、一致を確認する（講演資料 p.19, p.23）
# 実行: bin/rails runner script/step3_ranking.rb

ARTICLES = 1_000
DATES = (0...7).map { |i| (Date.new(2026, 10, 17) - i).strftime("%Y%m%d") } # 20261017 〜 20261011

# テストデータ: 日付ごとの { 記事ID => その日のPV数 }。乱数の種を固定して毎回同じデータにする
rng = Random.new(42)
daily = DATES.to_h do |date|
  views = (1..ARTICLES).to_h { |i| [ "article-#{i}", rng.rand(0..20) ] }
  [ date, views.reject { |_, v| v.zero? } ] # PV 0 の記事はその日のデータに入れない
end

# --- Ruby Hash 版: 7日分を足し合わせてソート ---
totals = Hash.new(0)
daily.each_value { |views| views.each { |article, v| totals[article] += v } }
# Valkey の ZRANGE ... REV と同じ並び順: スコアの高い順、同点ならメンバー名の降順
ruby_ranking = totals.sort_by { |article, score| [ score, article ] }.reverse

# --- Valkey 版: 日次キー（daily:YYYYMMDD）に入れて ZUNIONSTORE で合算 ---
daily.each do |date, views|
  key = "daily:#{date}"
  VALKEY.del(key)
  VALKEY.zadd(key, views.map { |article, v| [ v, article ] })
end
VALKEY.zunionstore("dest", DATES.map { |date| "daily:#{date}" })
valkey_ranking = VALKEY.zrange("dest", 0, -1, rev: true, with_scores: true)
                       .map { |article, score| [ article, score.to_i ] } # スコアは Float で返るので整数に

puts "Top 10 (Ruby / Valkey)"
ruby_ranking.first(10).zip(valkey_ranking.first(10)).each.with_index(1) do |(r, v), rank|
  puts format("%2d. %-12s %4d | %-12s %4d", rank, *r, *v)
end
puts "件数: Ruby #{ruby_ranking.size} / Valkey #{valkey_ranking.size}"
puts ruby_ranking == valkey_ranking ? "全順位が一致" : "不一致あり"
