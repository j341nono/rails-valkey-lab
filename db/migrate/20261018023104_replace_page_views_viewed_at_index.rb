# 方式A を調整済みの PostgreSQL にするため、viewed_at 単独のインデックスを複合インデックスに置き換える。
# [viewed_at, article_id] なら、集計に必要な列がインデックスだけで揃う（Index Only Scan）
class ReplacePageViewsViewedAtIndex < ActiveRecord::Migration[8.1]
  def change
    remove_index :page_views, :viewed_at
    add_index :page_views, [ :viewed_at, :article_id ]
  end
end
