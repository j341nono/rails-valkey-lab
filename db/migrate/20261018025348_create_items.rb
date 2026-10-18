# Vector Search 用。pgvector の vector 型（128次元）と HNSW インデックス（L2 距離）
class CreateItems < ActiveRecord::Migration[8.1]
  def change
    enable_extension "vector"
    create_table :items do |t|
      t.vector :embedding, limit: 128, null: false
    end
    add_index :items, :embedding, using: :hnsw, opclass: :vector_l2_ops # m=16, ef_construction=64（pgvector の既定値）
  end
end
