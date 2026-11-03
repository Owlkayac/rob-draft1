# 難易度のしくみと調整(初心者向け)

仕様書: `docs/specs/015-menu-and-difficulty.md`、記録: `docs/decisions/015-menu-and-difficulty.md`

## 用語
- **プリセット**: 数字の組み合わせを、名前をつけて、まとめたもの。ここでは「やさしい」「ふつう」「むずかしい」。
- **倍率**: 元の数字に「かける」数。0.8 なら 8 割、1.2 なら 2 割増し。
- **補正(モディファイア)**: 天敵の数字に倍率をかける仕組み(`docs/design/enemy-architecture.md` の 5)。

## 何をするか
ゲームを始める前のメニューで、「やくわり」と「なんいど」を選ぶ。難易度は、**そのプレイヤーにとっての、やさしさ**を表す(やさしい = 勝ちやすい)。選んだ難易度の数字が、農家さん・稲刈り機・ジェット・点数に効く。

## しくみ(流れ)
1. メニュー(`MenuController`)で選んで「スタート」を押すと、`StartRequest`(やくわり、なんいど)がサーバーに届く。
2. サーバー(`SetupService`)が、型と中身を確かめて、プレイヤーごとの表(`Player` をキーにした表)に覚える。
3. ラウンドが始まる。難易度の数字は、使う場所が、その都度 `SetupService` から読む。
   - 農家さんの数字: `Enemy/Stats.luau` の補正 `"Difficulty"` が、発見距離・気づく間・勘の確率・見失うまでの時間に倍率をかける。
   - 稲刈り機の「入るまでの待ち」: `Enemy/Behaviors/Sweep.luau` が、基本の秒数に `HarvesterEntryDelayBonus` を足す。
   - ジェットのため直し: `CrayfishService.luau` が倍率をかける。
   - 点数: `ScoreService.luau` が、最後に倍率をかけて整数に丸める。

## 調整のしかた(`Config.Difficulties`)
`Config.luau` の `Difficulties` の中の数字を書き換えて保存し、Studio で再生し直す。

| 項目 | やさしい | ふつう | むずかしい | 効くところ | 変えるときのめやす |
|---|---|---|---|---|---|
| `FarmerSightMultiplier` | 0.8 | 1.0 | 1.2 | 農家さんの、見つける距離 | 大きいほど、遠くから見つかる |
| `FarmerNoticeMultiplier` | 1.4 | 1.0 | 0.8 | 気づく間(見つけてから走り出すまで)の長さ | 大きいほど、逃げる猶予が長い。最低 0.4 秒は保つ(`DifficultyNoticeFloorSeconds`) |
| `FarmerHunchMultiplier` | 0.4 | 1.0 | 1.6 | 「勘」(だいたいの位置へ向かう)の確率 | 大きいほど、よく向かってくる。結果は 1 を超えない |
| `FarmerLoseSightMultiplier` | 0.7 | 1.0 | 1.4 | 見失うまでの時間 | 大きいほど、しつこく追う |
| `HarvesterEntryDelayBonus` | +1.5 | 0 | -1.0 | 稲刈り機が動き出すまでの待ち(秒。足す) | 大きいほど、予告から動き出すまでが長い。最小 0.5 秒(`HarvesterEntryDelayMinSeconds`)。画面の予告の長さも、この待ち + `HarvesterWarningExtraSeconds`(1秒)に合わせて変わる |
| `JetCooldownMultiplier` | 0.75 | 1.0 | 1.3 | ジェットのため直しの長さ | 大きいほど、ジェットをまた使えるまでが長い |
| `ScoreMultiplier` | 0.8 | 1.0 | 1.3 | 点数にかける倍率 | むずかしいほど高い |
| `PreyCount` | 2 | 3 | 5 | AIザリガニの数(農家さんで遊ぶとき。`PreyService` が、ラウンドの始まりに、この数だけ出す。1〜`PreyCountMax` に収める) | 多いほど、ぜんぶつかまえるのに時間がかかる |
| `PreySpeedMultiplier` | 0.9 | 1.0 | 1.1 | AIザリガニの、歩く速さとジェットの速さ(`PreyWalkSpeed` × この倍率。プレイヤーの農家さんは `FarmerPlayerWalkSpeed` = 15) | 大きいほど、逃げ足が速い |
| `PreyAwarenessMultiplier` | 0.8 | 1.0 | 1.2 | AIザリガニが、農家さんに気づいて逃げ出す距離(`PreySightDistance` × この倍率) | 大きいほど、遠くから逃げ出す |

- 倍率は、**0 より大きい数字**にする(0 や、マイナス、数字でない値は、1 倍として扱われる)。
- 農家さんモード(`Role = "Farmer"`)で効くのは、`Prey...` の3つと `ScoreMultiplier` だけ。`Farmer...`・`HarvesterEntryDelayBonus`・`JetCooldownMultiplier` は、このモードでは使われない(農家さんAI・稲刈り機・ジェットが出ないため)。農家さんモードの調整は `docs/design/farmer-mode.md`。
- **変えない数字**: 農家さんの追跡の速さの上限(`FarmerChaseMaxSpeedRatio`)と、稲刈り機の速さ(`HarvesterSpeed`)。理由は `docs/decisions/015-menu-and-difficulty.md`。
- `HarvesterEntryDelayBonus` を大きくしたら、稲刈り機がラウンドの中に走り切れるか、`Config.luau` の `HarvesterEntryDelayBonus` 付近のコメントの式で確かめる(やさしい: 165 + 4.5 + 126.3 + 1.2 ≒ 297 秒 < 300 秒)。
- 画面に出す名前は `Config.DifficultyLabels`、メニューに並ぶ順番は `Config.DifficultyOrder`。

## 新しい難易度を足すには(例: 「ちょうむずかしい」 = `Expert`)
1. `Config.Difficulties` に、`Expert = { ... }` を足す。**10 個の項目をすべて**書く(`Normal` をコピーして、数字を変えるのが楽)。
2. `Config.DifficultyLabels` に `Expert = "ちょうむずかしい"` を足す。
3. `Config.DifficultyOrder` に `"Expert"` を足す(並べたい位置に)。
4. 保存の形のキーは、自動で `Crayfish_Expert` のようになる。コードを変える必要はない。メニューのボタンも、自動で増える(ボタンが多いと文字が小さくなるので、Studio で見た目を確かめる)。

## 新しい「補正」を足すには
`Stats.RegisterModifier("名前", 関数)` で足す(`docs/design/enemy-architecture.md` の 5)。難易度の補正は、`Enemy/Stats.luau` の下のほうにある `"Difficulty"`。

## ベスト記録について
ベスト記録は、「やくわり」×「なんいど」の組み合わせごとに別々。保存の形は `docs/design/score.md` を見る。
