# rails-valkey-lab

## 目的

Kaigi on Rails 2026の講演「そのValkey、使いこなしていますか？」で紹介されたValkeyの活用方法について、PostgreSQLのみのRails実装と、PostgreSQLにValkeyを追加した実装を比較し、実行時間・メモリ使用量・運用コストの違いを検証する。

参照資料:
- `references/valkey.pdf`
- `references/valkey_slide_code.md`

技術共有会で実装内容と性能測定結果を発表することが最終目標。

## 実験1：直近7日間ランキング

実運用を想定し、次の2方式を比較する。Valkeyのみの方式は対象外とする。
目的は、ランキング取得の高速化と、追加の書き込み・メモリ・同期コストのトレードオフを明らかにすること。

**A：PostgreSQLのみ**
- Active Recordで閲覧イベントを1件ずつ保存する。
- SQLの `WHERE`、`GROUP BY`、`COUNT`、`ORDER BY` で直近7日間のTop 10を集計する。
- 調整済みのPostgreSQLを基準とするため、複合インデックス `[viewed_at, article_id]` を付ける。

**C：PostgreSQL + Valkey**
- Aと同様に、Active Recordで閲覧イベントを1件ずつ保存する。
- 追加で `ZINCRBY` を実行し、日別のSorted Setを更新する。`PageView` の `after_create_commit` で同期的に実行する（保存が確定した場合だけValkeyに反映する）。
- 日別キーには `EXPIRE` でPostgreSQLと同じ保持期間を付ける。
- `ZUNIONSTORE` で直近7日間を合算し、`ZRANGE` でTop 10を取得する。
- `WEIGHTS` による時間減衰ランキングも検証する。

**AとCに共通**
- 同じ閲覧イベントを使用し、ランキング結果の一致を確認する。
- 日付の区切りは日本時間（`config.time_zone = "Tokyo"`）。

**同期コストとして測るもの**
- 書き込みの増加分：1件あたりの書き込み時間（A：`create!`、C：`create!` + `ZINCRBY`）
- 再構築時間：PostgreSQLの閲覧イベントから日別Sorted Setを作り直す時間（SQLで日別集計 → `ZADD`）

**対象外（明記しておく）**
- ジョブキューによる非同期更新
- PostgreSQLの日別事前集計テーブル（Valkeyを使わない代表的な高速化手段）

## 実験2：Vector Search

- 一般的な実装：PostgreSQL + pgvector（HNSW）
- Valkey実装：Valkey Search（HNSW）
- 同一のベクトルを使用して、検索時間・メモリ使用量・Recall@10を比較する。

## 測定方針

- 同じデータを使い、結果の一致（実験2ではRecall@10）を確認してから測定する。
- 書き込み（1件ずつ）とランキング取得・検索を分けて測定する。
- 大量データの準備に使う一括投入（`insert_all` など）は測定対象とせず、参考値として扱う。
- ウォームアップ後に複数回測定し、中央値・最小・最大を記録する。
- メモリ使用量は、Rails・PostgreSQL・Valkeyを区別して記録する。
- データ件数を段階的に増やして比較する。
- 測定結果をCSVとして `results/` に保存する（Gitには含めない）。
- Active Recordのクエリキャッシュを無効にして測る（`rails runner` では有効になっている）。
- 一方の方式が必ず有利になると決めつけず、実測結果に基づいて考察する。
- 実測値と推測を区別し、都合の悪い結果も記録する。

## 実装方針

- Ruby on Railsを使用し、Pythonは使わない。
- 技術検証が目的であり、完成度の高いプロダクトは不要。
- 講演資料のように、短く理解しやすいコードを優先する。
- Web UI、認証、CRUD機能、過度な抽象化、不要な依存ライブラリは作らない・入れない。
- `rails runner` またはRakeタスクで実験できればよい。
- ただし、測定結果の正確性と再現性は確保する。

## 開発環境

開発時:
- Apple Silicon Mac。RailsはMac上で実行する
- PostgreSQLとValkeyはDocker Composeで起動する

最終測定時:
- UTM上のUbuntu ARM64 VM
- Docker ComposeでRails・PostgreSQL・Valkeyを別コンテナとして実行する（k8s/k3sは使わない。k3sは最後の追加実験のみ）
- GitHubからcloneして環境を再現する

最終的な性能比較はUbuntu VM内で条件を揃えて行う。

## 開発順序

Step 3〜5（Ruby Hash vs Valkey）とStep 8（PostgreSQL vs Valkeyのみ）は旧方針で完了済み。スクリプトは参考として残す。

Step 1: Railsの最小環境を構築する（完了）  
Step 2: ValkeyのSorted Setを動かす（完了）  
Step 3: Ruby Hash版とValkey版で直近7日間ランキングを実装する（完了・旧方針）  
Step 4: ランキングの実行時間・メモリ使用量を比較する（完了・旧方針）  
Step 5: WEIGHTSによる重み付きランキングを試す（完了・旧方針）  
Step 6: Active Record + PostgreSQLを導入する（完了）  
Step 7: 閲覧イベントをPostgreSQLとValkeyに記録し、直近7日間Top 10が一致することを確認する（完了）  
Step 8: PostgreSQLとValkeyのみでランキングを比較する（完了・旧方針）  
Step 9: 方式Cを実装する（`after_create_commit` で `ZINCRBY`、`EXPIRE`、再構築処理）。AとCのランキング一致を確認する  
Step 10: AとCを比較測定する（書き込み・ランキング取得・メモリ・再構築時間。WEIGHTSを含む）  
Step 11: pgvectorとValkey SearchでVector Searchを実装・比較する  
Step 12: GitHub経由でUbuntu VMに移し、Docker Composeで最終測定する（Railsもコンテナ化。CPU・メモリ上限、ネットワーク遅延を数段階で測定）  
Step 13: 結果を整理して共有会で発表する  
追加実験（Step 13の後）: 同じ測定をk3sでも行い、Composeとの差を見る  

## 最重要ルール

**必ず1ステップずつ進めること。**

- 一度に全機能を実装しない。
- 私が指定したStepだけを実装する。
- 次のStepには私の許可なく進まない。
- 各Stepの完了時に、実装内容と主要コード・Railsの仕組みを簡潔に説明する。
- 先のStepのために複雑な設計を先回りして作らない。
- Rails初心者でも理解できる実装を優先する。
