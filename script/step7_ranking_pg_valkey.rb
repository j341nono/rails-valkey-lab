# Step 7: 同じ閲覧イベントを PostgreSQL と Valkey に記録し、直近7日間 Top 10 の一致を確認する
# 実行: bin/rails runner script/step7_ranking_pg_valkey.rb

EVENTS = 10_000
ARTICLES = 100
TODAY = Date.new(2026, 10, 17)
DATES = (0...7).map { |i| TODAY - i }                # 集計対象: 10/11 〜 10/17
ALL_DATES = DATES + [ TODAY - 7 ]                     # 10/10 も混ぜ、範囲外が除外されるか確認する
daily_key = ->(date) { "daily:#{date.strftime('%Y%m%d')}" }

# テストデータ: 8日間にランダムに散らばった閲覧イベント（乱数の種を固定）。
# 日付の区切りは日本時間（config.time_zone = "Tokyo"）。in_time_zone で JST の 0:00 になる
rng = Random.new(42)
events = Array.new(EVENTS) do
  date = ALL_DATES.sample(random: rng)
  { article_id: rng.rand(1..ARTICLES), viewed_at: date.in_time_zone + rng.rand(86_400) }
end

# --- 記録 ---
PageView.delete_all
PageView.insert_all(events) # 1件ずつ create するより速い一括 INSERT

ALL_DATES.each { |date| VALKEY.del(daily_key.(date)) }
VALKEY.pipelined do |pipe| # 1イベント1回の ZINCRBY を、まとめて送る
  events.each { |e| pipe.zincrby(daily_key.(e[:viewed_at].to_date), 1, e[:article_id]) }
end

# --- PostgreSQL: WHERE で7日間に絞り、GROUP BY + COUNT で集計 ---
# Valkey は同点をメンバー名（文字列）の降順で返すので、SQL も article_id を文字列として並べる
sql_ranking = PageView
  .where(viewed_at: DATES.last.in_time_zone...(TODAY + 1).in_time_zone) # JST の 10/11 0:00 〜 10/18 0:00
  .group(:article_id)
  .order(Arel.sql("COUNT(*) DESC, article_id::text DESC"))
  .count # => { article_id => 件数 }（並び順を保ったHash）
  .to_a

# --- Valkey: ZUNIONSTORE で7日分を合算し、ZRANGE で取得 ---
VALKEY.zunionstore("dest", DATES.map(&daily_key))
valkey_ranking = VALKEY.zrange("dest", 0, -1, rev: true, with_scores: true)
                       .map { |article_id, score| [ article_id.to_i, score.to_i ] }

puts "Top 10 (PostgreSQL / Valkey)"
sql_ranking.first(10).zip(valkey_ranking.first(10)).each.with_index(1) do |(s, v), rank|
  puts format("%2d. article %3d: %3d | article %3d: %3d", rank, *s, *v)
end
puts "7日間のイベント数: PostgreSQL #{sql_ranking.sum(&:last)} / Valkey #{valkey_ranking.sum(&:last)} (全体 #{EVENTS})"
puts "Top 10: #{sql_ranking.first(10) == valkey_ranking.first(10) ? '一致' : '不一致'}"
puts "全順位: #{sql_ranking == valkey_ranking ? '一致' : '不一致'}"
