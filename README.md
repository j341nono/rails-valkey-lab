# rails-valkey-lab

Kaigi on Rails 2026「そのValkey、使いこなしていますか？」の内容を Rails で検証するリポジトリ。

## セットアップ

```sh
bundle install
docker compose up -d   # Valkey (localhost:6380) と PostgreSQL (localhost:5433)
bin/rails db:prepare   # DB作成 + マイグレーション
```

## 実行

```sh
bin/rails runner script/step2_sorted_set.rb          # Sorted Set の基本操作
bin/rails runner script/step3_ranking.rb             # 旧方針・参考: 直近7日間ランキング（Ruby Hash / Valkey）
bin/rails runner script/step4_benchmark.rb           # 旧方針・参考: 集計時間・メモリ → results/step4_ranking.csv
bin/rails runner script/step5_weighted_ranking.rb    # 旧方針・参考: WEIGHTS → results/step5_weighted_ranking.csv
bin/rails runner script/step7_ranking_pg_valkey.rb   # 直近7日間ランキング（PostgreSQL / Valkey）
bin/rails runner script/step8_benchmark_pg_valkey.rb # 旧方針・参考: PostgreSQL / Valkeyのみ → results/step8_*.csv（EVENTS=300000,3000000 で件数指定）
bin/rails runner script/step9_pg_with_valkey.rb      # 方式A / 方式C の一致・保持期間・再構築の確認
bin/rails runner script/step10_benchmark_a_vs_c.rb   # 方式A / 方式C の書き込み・取得・再構築・メモリ → results/step10_*.csv
```

## 停止

```sh
docker compose down
```
