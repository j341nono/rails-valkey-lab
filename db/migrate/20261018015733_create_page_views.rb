# 閲覧イベントを1件1行で保存するテーブル（日別の事前集計はしない）
class CreatePageViews < ActiveRecord::Migration[8.1]
  def change
    create_table :page_views do |t|
      t.bigint :article_id, null: false
      t.datetime :viewed_at, null: false
    end
    add_index :page_views, :viewed_at # 直近7日間の絞り込み（WHERE viewed_at）用
  end
end
