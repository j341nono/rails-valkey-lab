# 閲覧イベント（1件1行）。
# 方式A: PostgreSQL のみで集計する
# 方式C: 保存が確定したあと、Valkey の日別 Sorted Set も更新する（ランキングは Valkey で集計）
class PageView < ApplicationRecord
  RETENTION_DAYS = 30
  WEIGHTS = [ 100, 90, 81, 73, 66, 59, 53 ] # 講演資料 p.30 の重みを100倍した整数（新しい日から順。Step 5 参照）

  # 方式A（PostgreSQL のみ）を測るときは false にする
  class_attribute :sync_valkey, default: true
  after_create_commit :increment_daily_ranking, if: :sync_valkey

  # 旧方針のスクリプトが使う daily:* とぶつからないよう、名前空間を付ける
  def self.daily_key(date) = "page_views:daily:#{date.strftime('%Y%m%d')}"

  # 日別キーは、その日から RETENTION_DAYS 日後が終わるまで残す
  def self.expire_at(date) = (date + RETENTION_DAYS + 1).in_time_zone.to_i

  def self.last_7_days(today) = (0...7).map { |i| today - i } # 新しい日から順

  # 方式A: WHERE で7日間に絞り、GROUP BY で集計する。limit: nil なら全件
  # 同点は Valkey と同じく article_id を文字列として降順に並べる（Step 7 参照）
  def self.top_from_postgresql(today: Date.current, limit: 10, weighted: false)
    dates = last_7_days(today)
    scope = where(viewed_at: dates.last.in_time_zone...(today + 1).in_time_zone).group(:article_id).limit(limit)
    if weighted
      weight = "CASE " + dates.zip(WEIGHTS).map { |d, w| "WHEN viewed_at >= '#{d.in_time_zone.utc.to_fs(:db)}' THEN #{w}" }.join(" ") + " END"
      scope.order(Arel.sql("SUM(#{weight}) DESC, article_id::text DESC")).sum(Arel.sql(weight)).to_a
    else
      scope.order(Arel.sql("COUNT(*) DESC, article_id::text DESC")).count.to_a
    end
  end

  # 方式C: ZUNIONSTORE で7日分を合算し、ZRANGE で取得する。コマンドはまとめて1往復で送る
  # 集計結果の dest は一時的なキーなので、60秒で消えるようにする
  def self.top_from_valkey(today: Date.current, limit: 10, weighted: false)
    dest = "page_views:top:#{today.strftime('%Y%m%d')}:#{weighted ? 'weighted' : 'simple'}"
    _, top = VALKEY.pipelined do |pipe|
      pipe.zunionstore(dest, last_7_days(today).map { |d| daily_key(d) }, weights: weighted ? WEIGHTS : nil)
      pipe.zrange(dest, 0, limit ? limit - 1 : -1, rev: true, with_scores: true)
      pipe.expire(dest, 60)
    end
    top.map { |article_id, score| [ article_id.to_i, score.to_i ] }
  end

  # PostgreSQL の閲覧イベントから、from〜to の日別 Sorted Set を作り直す（Valkey が消えた・ずれたとき用）
  def self.rebuild_valkey(from:, to:)
    jst_date = Arel.sql("(viewed_at AT TIME ZONE 'UTC' AT TIME ZONE '#{Time.zone.tzinfo.name}')::date")
    counts = where(viewed_at: from.in_time_zone...(to + 1).in_time_zone).group(jst_date, :article_id).count
    by_date = counts.group_by { |(date, _), _| date }

    (from..to).each do |date|
      key = daily_key(date)
      rows = by_date.fetch(date, []).map { |(_, article_id), count| [ count, article_id ] }
      VALKEY.multi do |tx| # 削除と再作成をまとめて実行し、作り直し途中の状態を見せない
        tx.del(key)
        tx.zadd(key, rows) if rows.any?
        tx.expireat(key, expire_at(date))
      end
    end
  end

  private

  # 方式C の書き込み。Valkey に失敗しても PostgreSQL の保存は確定済みなので、ログに残して rebuild_valkey で直す
  def increment_daily_ranking
    date = viewed_at.to_date # config.time_zone（Tokyo）の日付
    key = self.class.daily_key(date)
    VALKEY.pipelined do |pipe|
      pipe.zincrby(key, 1, article_id)
      pipe.expireat(key, self.class.expire_at(date))
    end
  rescue Redis::BaseError => e
    Rails.logger.error("Valkey の更新に失敗: #{e.class} #{e.message}")
  end
end
