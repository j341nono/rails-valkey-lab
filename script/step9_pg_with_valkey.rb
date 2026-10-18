# Step 9: 方式C（PostgreSQL + Valkey）の書き込み・取得・再構築を確認し、方式A とランキングが一致するか確かめる
# 実行: bin/rails runner script/step9_pg_with_valkey.rb

EVENTS = 3_000
ARTICLES = 100
TODAY = Date.current
FIRST_DAY = TODAY - (PageView::RETENTION_DAYS - 1)

ActiveRecord::Base.connection.disable_query_cache! # rails runner では有効。毎回 DB に問い合わせる

check = ->(label, ok) { puts "#{ok ? 'OK ' : 'NG '} #{label}"; raise "失敗: #{label}" unless ok }
same_rankings = lambda do
  [ false, true ].all? do |weighted|
    PageView.top_from_postgresql(today: TODAY, limit: nil, weighted:) == PageView.top_from_valkey(today: TODAY, limit: nil, weighted:)
  end
end
daily_keys = (FIRST_DAY..TODAY).map { |d| PageView.daily_key(d) }

# --- 準備: PostgreSQL と Valkey の page_views:* を空にする ---
PageView.delete_all
VALKEY.scan_each(match: "page_views:*") { |key| VALKEY.del(key) }

# --- 書き込み: 実際のアプリと同じく1件ずつ create!（after_create_commit で ZINCRBY） ---
rng = Random.new(42)
start_at = FIRST_DAY.in_time_zone.to_i
EVENTS.times do
  PageView.create!(article_id: rng.rand(1..ARTICLES), viewed_at: Time.zone.at(start_at + rng.rand(PageView::RETENTION_DAYS * 86_400)))
end

top_a = PageView.top_from_postgresql(today: TODAY)
top_c = PageView.top_from_valkey(today: TODAY)
puts "Top 10 (A: PostgreSQL / C: Valkey)"
top_a.zip(top_c).each.with_index(1) { |(a, c), rank| puts format("%2d. article %3d: %3d | article %3d: %3d", rank, *a, *c) }

check.("A と C の全順位が一致（重みなし・重み付き）", same_rankings.())
check.("日別キーに保持期間が付いている（今日のキーの残り #{VALKEY.ttl(PageView.daily_key(TODAY)) / 86_400} 日）", daily_keys.all? { |k| VALKEY.ttl(k) > 0 })

# --- ロールバックされた保存は Valkey に反映されない（after_create_commit） ---
before = VALKEY.zscore(PageView.daily_key(TODAY), 1)
PageView.transaction do
  PageView.create!(article_id: 1, viewed_at: Time.current)
  raise ActiveRecord::Rollback
end
check.("ロールバックした保存は Valkey に反映されない", VALKEY.zscore(PageView.daily_key(TODAY), 1) == before)

# --- 再構築: Valkey が消えた場合・ずれた場合に、PostgreSQL から作り直せる ---
VALKEY.del(*daily_keys)
check.("Valkey を消すと C の結果は空になる", PageView.top_from_valkey(today: TODAY).empty?)
PageView.rebuild_valkey(from: FIRST_DAY, to: TODAY)
check.("消えた日別キーを再構築すると A と一致", same_rankings.())

VALKEY.zincrby(PageView.daily_key(TODAY), 100, 1) # 二重カウントなどでずれた状態を作る
check.("ずれると A と一致しない", !same_rankings.())
PageView.rebuild_valkey(from: FIRST_DAY, to: TODAY)
check.("ずれた日別キーを再構築すると A と一致", same_rankings.())
