# 点数とベスト記録のしくみ(初心者向け)

仕様書: `docs/specs/012-food-score-best.md`

## 点数の決まり方
点数 = 食べた餌の点 + 生き延びた秒数 + クリアのボーナス。
- 餌は橙色の丸。ザリガニが近づくと(潜っていないとき)食べられて、10点入る。6秒後に別の場所に新しく出る。
- 生き延びた1秒ごとに1点。クリアすると、さらに100点。
- 計算はすべてサーバー(`ScoreService`)。画面(`GuiController`)は、送られてきた数字を出すだけ。

## 部品の役割
- `FoodService`: 餌を置く・食べる判定・置き直し。
- `ScoreService`: 点数の計算とベスト記録の保存・読み込み。
- `RoundService`: ラウンドの始まり・毎秒・終わりに、`ScoreService` を呼ぶ。

## 数字の調整(Config.luau)
`FoodCount`(餌の数)、`FoodPoints`(1つの点)、`FoodEatDistance`(食べられる距離)、`FoodRespawnSeconds`(出なおす時間)、`ScorePerSecond`、`ClearBonus`、`FoodSize`、`FoodColor`、`FoodHoverHeight`(ういている高さ)。

## ベスト記録を Studio で確かめるには
保存には DataStore(Roblox のデータ保存の仕組み)を使う。同じ人の保存が同時に二重に走らないよう、保存中は待ち、終わったあとでベストが変わっていれば、もう一度保存する。公開していない Studio では、保存も読み込みも失敗する。そのときは、警告が1回出て、そのプレイ中だけの記録になる(エラーでは止まらない)。
1. Studio で、ゲームを公開する(File の Publish to Roblox)。
2. Game Settings の「Security」で、「Enable Studio Access to API Services」を ON にする。
3. 遊んで、ベストを更新して、止めてからもう一度遊ぶ。ベストが残っていれば成功。

## ベストを消したいとき
`Config.BestScoreStoreName` を、別の名前(例: `"BestScores2"`)に変える。新しい入れ物になるので、全員の記録が 0 から始まる。古い入れ物は残る(消えない)。

## 「ベスト更新!」の表示について
ベストを読み込む前にラウンドが終わると、一時的に「ベスト更新」になることがある。読み込みが終わって、保存してあるベストが同じか高いと分かったら、「ベスト更新」を取り消して、ベストを保存してある値に直し、画面に送り直す(誤って「ベスト更新!」が出ない)。
