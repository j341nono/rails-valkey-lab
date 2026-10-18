# Step 11: Vector Search を PostgreSQL + pgvector（HNSW）と Valkey Search（HNSW）で比べる
# 実行: bin/rails runner script/step11_vector_search.rb
#       件数を変える場合: ITEMS=10000,100000 bin/rails runner script/step11_vector_search.rb
# 結果: results/step11_build.csv（投入・インデックス作成・メモリ）, results/step11_search.csv（検索時間・Recall@10）
require "csv"

ITEM_SIZES = ENV.fetch("ITEMS", "10000,100000").split(",").map(&:to_i)
DIM = 128
CLUSTERS = 50     # 実際の埋め込みに近づけるため、50個の中心のまわりに散らばるデータにする
QUERIES = 100
K = 10
EF_SEARCH = [ 10, 40, 100 ] # 検索時の探索幅（pgvector: hnsw.ef_search / Valkey: EF_RUNTIME）。両方同じ値で測る
BATCH = 1_000
INDEX = "items_idx"

ActiveRecord::Base.logger = nil
ActiveRecord::Base.connection.disable_query_cache!
DB = ActiveRecord::Base.connection

def elapsed_ms
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  yield
  (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000
end

# 正規分布の乱数（Box-Muller 法）
def gaussian(rng) = Math.sqrt(-2 * Math.log(1 - rng.rand)) * Math.cos(2 * Math::PI * rng.rand)

rng = Random.new(42)
centers = Array.new(CLUSTERS) { Array.new(DIM) { gaussian(rng) } }
make_vector = -> { centers.sample(random: rng).map { |c| c + 0.3 * gaussian(rng) } }
queries = Array.new(QUERIES) { make_vector.() } # データとは別に作った検索ベクトル

pg_search = ->(q) { Item.nearest_neighbors(:embedding, q, distance: "euclidean").limit(K).pluck(:id) }
valkey_search = lambda do |q, ef|
  _, *keys = VALKEY.call("FT.SEARCH", INDEX, "*=>[KNN #{K} @embedding $v EF_RUNTIME #{ef}]",
                         "PARAMS", "2", "v", q.pack("e*"), "RETURN", "0", "DIALECT", "2")
  keys.map { |key| key.delete_prefix("item:").to_i }
end
valkey_index_ready = lambda do |items|
  info = VALKEY.call("FT.INFO", INDEX).each_slice(2).to_h
  info["backfill_in_progress"] == "0" && info["num_docs"].to_i == items
end
valkey_memory = -> { [ VALKEY.info("memory")["used_memory"].to_i, VALKEY.info("search")["search_used_memory_bytes"].to_i ] }

versions = [ RUBY_VERSION, DB.select_value("SHOW server_version")[/\S+/], DB.select_value("SELECT extversion FROM pg_extension WHERE extname = 'vector'"), VALKEY.info("server")["valkey_version"] ]
puts "Ruby #{versions[0]} / PostgreSQL #{versions[1]} + pgvector #{versions[2]} / Valkey #{versions[3]}"
build_rows = []
search_rows = []

ITEM_SIZES.each do |items|
  vectors = Array.new(items) { make_vector.() } # id は 1 から順に振られる
  ids = (1..items).to_a

  # --- PostgreSQL: 投入 → HNSW インデックス作成（schema.rb と同じ定義） ---
  DB.execute("TRUNCATE items RESTART IDENTITY")
  DB.remove_index(:items, :embedding) if DB.index_exists?(:items, :embedding)
  pg_insert = vectors.each_slice(BATCH).sum { |batch| elapsed_ms { Item.insert_all(batch.map { |v| { embedding: v } }) } }
  DB.execute("SET maintenance_work_mem = '1GB'") # 既定の 64MB だとグラフが収まらず作成が遅くなる
  pg_build = elapsed_ms { DB.add_index(:items, :embedding, using: :hnsw, opclass: :vector_l2_ops) }
  DB.execute("VACUUM ANALYZE items")
  pg_table, pg_index = DB.select_rows("SELECT pg_table_size('items'), pg_indexes_size('items')").first

  # --- Valkey: 投入（HASH） → FT.CREATE でインデックス作成（作成完了まで待つ） ---
  VALKEY.call("FT.DROPINDEX", INDEX) rescue nil
  VALKEY.scan_each(match: "item:*", count: 1_000).each_slice(1_000) { |keys| VALKEY.del(*keys) }
  mem_before, search_before = valkey_memory.()
  valkey_insert = ids.zip(vectors).each_slice(BATCH).sum do |batch|
    elapsed_ms { VALKEY.pipelined { |pipe| batch.each { |id, v| pipe.hset("item:#{id}", "embedding", v.pack("e*")) } } }
  end
  mem_data, = valkey_memory.()
  valkey_build = elapsed_ms do
    VALKEY.call("FT.CREATE", INDEX, "ON", "HASH", "PREFIX", "1", "item:", "SCHEMA", "embedding", "VECTOR", "HNSW", "10",
                "TYPE", "FLOAT32", "DIM", DIM.to_s, "DISTANCE_METRIC", "L2", "M", "16", "EF_CONSTRUCTION", "64")
    sleep 0.01 until valkey_index_ready.(items)
  end
  _, search_after = valkey_memory.()

  # data_bytes: PostgreSQL はテーブル（ディスク上）、Valkey は HASH の増加分（メモリ上）
  # index_bytes: PostgreSQL は HNSW インデックス（ディスク上）、Valkey は search_used_memory_bytes の増加分（メモリ上）
  build_rows << [ items, "postgresql", pg_insert.round(1), pg_build.round(1), pg_table, pg_index ]
  build_rows << [ items, "valkey", valkey_insert.round(1), valkey_build.round(1), mem_data - mem_before, search_after - search_before ]

  # --- 正解: インデックスを使わず全件と距離を比べた（総当たりの）上位10件 ---
  exact = Item.transaction do
    DB.execute("SET LOCAL enable_indexscan = off")
    queries.map { |q| pg_search.(q) }
  end

  # データが少ないと PostgreSQL は HNSW を使わず全件を読むので、実際の実行方式も記録する
  pg_sql = Item.nearest_neighbors(:embedding, queries.first, distance: "euclidean").limit(K).select(:id).to_sql
  pg_scan = DB.select_values("EXPLAIN #{pg_sql}").grep(/Scan/).first.to_s[/(Index|Seq) Scan/]

  # --- 検索時間と Recall@10（1クエリずつ。ウォームアップ後に全クエリを測る） ---
  EF_SEARCH.each do |ef|
    DB.execute("SET hnsw.ef_search = #{ef}")
    { "postgresql" => ->(q) { pg_search.(q) }, "valkey" => ->(q) { valkey_search.(q, ef) } }.each do |store, search|
      queries.first(10).each { |q| search.(q) }
      results = []
      times = queries.map { |q| elapsed_ms { results << search.(q) } }.sort
      recall = results.zip(exact).sum { |got, truth| (got & truth).size } / (QUERIES * K).to_f
      search_rows << [ items, store, ef, times[QUERIES / 2].round(3), times[(QUERIES * 0.95).ceil - 1].round(3), times.first.round(3), times.last.round(3), recall.round(4), store == "postgresql" ? pg_scan : nil ]
    end
  end
  DB.execute("RESET hnsw.ef_search")

  puts "#{items} items"
  build_rows.select { |r| r[0] == items }.each do |r|
    puts format("  %-10s 投入 %8.1f ms  インデックス作成 %8.1f ms  データ %6.1f MB  インデックス %6.1f MB", r[1], r[2], r[3], r[4] / 1e6, r[5] / 1e6)
  end
  search_rows.select { |r| r[0] == items }.each do |r|
    puts format("  %-10s ef=%-3d median %7.3f ms  p95 %7.3f ms  Recall@10 %.3f  %s", r[1], r[2], r[3], r[4], r[7], r[8])
  end
end

FileUtils.mkdir_p("results")
CSV.open("results/step11_build.csv", "w") do |csv|
  csv << %w[items store insert_ms index_build_ms data_bytes index_bytes ruby_version pg_version pgvector_version valkey_version]
  build_rows.each { |row| csv << row + versions }
end
CSV.open("results/step11_search.csv", "w") do |csv|
  csv << %w[items store ef_search median_ms p95_ms min_ms max_ms recall_at_10 pg_scan ruby_version pg_version pgvector_version valkey_version]
  search_rows.each { |row| csv << row + versions }
end
puts "saved: results/step11_build.csv, results/step11_search.csv"
