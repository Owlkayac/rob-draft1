# 農家さんモードの仕組みと調整(初心者向け)

仕様書: `docs/specs/016-farmer-mode.md`、記録: `docs/decisions/016-farmer-mode.md`

## 用語
- **AI(エーアイ)**: プレイヤーの代わりに、コンピューター(サーバーのコード)が動かす相手。ここでは、ザリガニ。
- **Attribute(属性)**: モデルやプレイヤーにつけられる「名前つきのメモ」。クライアントも読める。
- **ScaleTo**: モデルを、まるごと何倍かの大きさにする命令。プレイヤーを巨人にするのに使う。
- **Clone(複製)**: Roblox のものを、そっくり1つ増やす命令。AIザリガニの「見本」を増やすのに使う。
- **世代(トークン)**: 「古い待ち・古いループ」を無効にするための番号。番号が変わったら、古いものは、何もしないで終わる。

## 何をするか
メニューで「農家さん」を選んで「スタート」を押すと、プレイヤーが巨人の農家さんになる。田んぼにいるAIのザリガニ(やさしい2 / ふつう3 / むずかしい5 ひき)を、300秒の間に、ぜんぶつかまえるとクリア。時間切れは「にげられた…」。

## 流れ(開始から終了まで)
1. 「スタート」(`StartRequest`)が、`SetupService` に通る。`Role = "Farmer"` が決まり、Player の Attribute `Role` にも入る。
2. `RoundService` が、世界を最初に戻す(`resetWorld`。餌は置かない、農家さんAIは消える、前のAIザリガニも消える)。キャラクターが生まれ直す。
3. キャラクターが生まれると、`RoundService` が、農家さんのラウンドを始める(`startFarmerRound`): ふだんと同じようにラウンドを始め(経過時間・稲の育ち・点数を最初に戻す)、`FarmerPlayer.Apply` でプレイヤーを巨人にし、`OnRoundStart` に登録された関数を呼ぶ。
4. `PreyService` が、AIザリガニを出す(見本を `Clone`。出現は田んぼの北側)。Attribute `PreyRemaining` に数を入れる。
5. 毎 `EnemyTickSeconds`(0.2秒)、`PreyService` の1つのループが、つかまえる判定 → 各AIの判断、を行う。
6. 終わり方は、どれも `RoundService.finishRound` で、点数を決めて、結果の画面を出す。
   - ぜんぶつかまえた → `RoundService.NotifyAllPreyCaught` → `Cleared`(ぜんいん つかまえた!)
   - 時間切れ(300秒)→ `Caught`(にげられた…)
   - AIが1ぴきも出せなかった(見本が作れない・全部作れない)、または、壊れたAIが出し直せず、つかまえた数が 0 のまま全滅した → `RoundService.NotifyCaught` → `Caught`(にげられた…)
   - (まず起きないが)プレイヤーが倒れた → `Caught`
   - 状態の種類は増やさず、すべて `Caught` として扱う(`Cleared` は「ぜんぶつかまえた」ときだけ)
7. 終わると、`OnRoundEnd` で、残っているAIザリガニが消える。巨人は、結果の画面の間は、そのまま(動けない)。
8. 「もう一度」: 同じ設定で、2〜に戻る。「メニューへ」: AIが消え、カメラのズーム距離が元に戻り、キャラクターが生まれ直して(巨人でなくなる)メニューが出る。

## AIザリガニの状態(`PreyService.luau`)
| 状態 | いつ | 何をする |
|---|---|---|
| Wander(うろうろ) | ふだん。出現から `PreyStartGraceSeconds` の間も | 田んぼの中のランダムな点へ、ゆっくり(`PreyWanderSpeedRatio` 倍)歩く。着くと、確率 `PreyWanderPauseChance` で、`PreyWanderPauseSecondsMin`〜`Max` 立ち止まる |
| Flee(にげる) | 農家さんが `PreySightDistance × PreyAwarenessMultiplier` 以内 | 農家さんから**遠ざかる向き**に、`PreyFleeStepStuds` 先の点へ、全速力(`PreyWalkSpeed × PreySpeedMultiplier`)で走る。壁ぎわでは、壁にそって逃げる。角に追いつめられると動けない。`PreyCalmRatio` 倍より離れたら、うろうろに戻る |
| Dive(潜る) | 農家さんが `PreyDiveDistance` 以内で、使えて、確率 `PreyDiveChance` で当たったとき | `PreyDiveSeconds` 潜る(動けない・半透明・モデルの Attribute `Hidden = true`)。浮上してから `PreyDiveCooldownSeconds` は潜れない |
| Jet(ジェット) | 農家さんが `PreyJetDistance` 以内で、使えて、確率 `PreyJetChance` で当たったとき | 遠ざかる向きに、`JetSeconds` のあいだ、`JetSpeedMultiplier` 倍の速さ(モデルの Attribute `Jetting = true`。クライアントが尻尾と粒子を動かす)。終わってから `PreyJetCooldownSeconds` は使えない |

- **反応の遅れ**: 状態を変える前に、`PreyReactionSecondsMin`〜`Max`(0.2〜0.5秒)待つ。その間に農家さんが離れたら、変えない。完璧には逃げない。
- **「くじ」**: 潜る・ジェットは、近づいたとき、1回だけ確率でくじを引く。はずれたら `PreyAbilityRollSeconds` は引かない(0.2秒ごとに引くと、ほぼ必ず当たってしまうため)。ジェットを先に引く(近いとき)。
- 潜る・ジェットが終わると、「にげる」に戻る(まだ近ければ逃げ続け、離れていれば、うろうろに戻る)。

## 壊れたAIザリガニの扱い
モデルが壊れた・消えた・倒れたAIは、**つかまえた扱いにしない**(点も、つかまえた数も、増えない)。
1. 見本の複製で、出現範囲(田んぼの北側)のランダムな位置に、**新しく出し直す**(のこりのひき数は、そのまま)。
2. 出し直せなければ、数から外す(のこりが 1 減る。警告は1回だけ)。
3. のこりが 0 になったとき、つかまえた数が 1 以上なら `Cleared`、0 なら `Caught`(にげられた…)で終わる。「つかまえていないのに、クリア」にならないための決まり。

## AIザリガニどうしの衝突
AIザリガニの全部品は、衝突グループ `"Prey"`(`PhysicsService`)に入っていて、`"Prey"` どうしは、ぶつからない(押し合って止まらない)。床(`Default`)とは、ぶつかったまま(すり抜けて落ちない)。人型(Humanoid)は、動いている間に、部品の `CanCollide` を `true` に戻すことがあるので、`CanCollide = false` だけでは防げない。だから、グループで防いでいる。

## 稲刈り機の予告の長さ(ザリガニのモード)
画面の予告「稲刈り機が動き出した!」は、**そのプレイヤーの難易度の「入るまでの待ち」+ `HarvesterWarningExtraSeconds`(1秒)** だけ出る(待ち = `HarvesterEntryDelaySeconds + 難易度の HarvesterEntryDelayBonus`、最小 `HarvesterEntryDelayMinSeconds`)。難易度は Player の Attribute `Difficulty` から読む。例: ふつうなら 3 + 1 = 4 秒、やさしいなら 4.5 + 1 = 5.5 秒、むずかしいなら 2 + 1 = 3 秒。

## つかまえる判定(サーバー)
`PreyService` が、毎回の判断の最初に、プレイヤー(遊んでいる間だけ)の `HumanoidRootPart` と、各AIザリガニの、**横方向(XZ)の距離**を調べる。
- 潜っていない: `FarmerCatchDistance × 巨人の大きさ`(4 × 2.5 = 10)以下
- 潜っている: `FarmerCatchHiddenDistance × 巨人の大きさ`(2 × 2.5 = 5)以下
つかまえたら、`ScoreService.AddPoints`(`PreyCatchPoints` = 100)で点を足して、モデルを消し、`PreyRemaining` を1減らす。0 になったら、`RoundService.NotifyAllPreyCaught` で、クリア。
「巨人の大きさ」は、`FarmerPlayer.GetScale`(実際に巨人になっている倍率)。まだ大きくなっていない間・大きくできなかったときは 1 倍の距離になる。

## 点数
点数 = (`つかまえた数 × PreyCatchPoints` +(クリアのとき)`のこり秒 × PreyTimeBonusPerSecond + ClearBonus`)× `ScoreMultiplier`(難易度)。丸めて整数。
- 例: ふつう(×1.0)で、3びきをのこり 100 秒でクリア → 300 + 100 + 100 = 500 点。
- 時間切れ(にげられた): つかまえた数 × 100 だけ(ボーナスなし)。
- 農家さんには、「生き延びた秒数」の点は入らない。ベスト記録は、「農家さん」×「なんいど」ごとに別。

## 調整のしかた(`Config.luau`)
`Config.luau` の「農家さんモード」の部分の数字を書き換えて保存し、Studio で再生し直す。**時間・間隔・距離は 0 にしない**(0 のままだと、動かなくなったり、割り算が壊れたりする。コードの中でも 0.001 より小さくはならないようにしてあるが、約束として)。

| 数字 | 初期値 | 変えると |
|---|---|---|
| `FarmerPlayerWalkSpeed` | 15 | プレイヤーの農家さんの速さ。大きいほど、つかまえやすい(AIは 13 × 難易度) |
| `FarmerPlayerCameraMin` / `Max` | 20 / 60 | カメラのズーム距離。巨人が大きく見えすぎ・小さく見えすぎのとき |
| `FarmerScale`(共用) | 2.5 | 巨人の大きさ。つかまえる距離も、これに比例する |
| `FarmerCatchDistance` / `FarmerCatchHiddenDistance`(共用) | 4 / 2 | つかまえる距離(標準サイズ基準。× 巨人の大きさ) |
| `PreyWalkSpeed` | 13 | AIの速さ。プレイヤー(15)より遅いので、いつかは追いつく。大きくすると、むずかしい |
| `PreySightDistance` | 35 | 気づいて逃げ出す距離。大きいと、遠くから逃げられる |
| `PreyDiveDistance` / `PreyDiveChance` / `PreyDiveSeconds` / `PreyDiveCooldownSeconds` | 16 / 0.5 / 3 / 7 | 潜る距離・確率・長さ・ため直し |
| `PreyJetDistance` / `PreyJetChance` / `PreyJetCooldownSeconds` | 11 / 0.7 / 9 | ジェットの距離・確率・ため直し(噴射の長さと速さは、プレイヤーと同じ `JetSeconds`・`JetSpeedMultiplier`) |
| `PreyReactionSecondsMin` / `Max` | 0.2 / 0.5 | 反応の遅れ。小さいほど、完璧に逃げる(むずかしい) |
| `PreyStartGraceSeconds` | 3 | 出現してから、逃げない時間 |
| `PreyFleeStepStuds` | 20 | 逃げるとき、1回の目的地までの距離 |
| `PreyWallMargin` | 8 | AIが、壁からこれより内側を動く。大きいと、壁ぎわに追いつめにくい |
| `PreyCatchPoints` / `PreyTimeBonusPerSecond` | 100 / 1 | 点数 |
| `Difficulties.*.PreyCount` / `PreySpeedMultiplier` / `PreyAwarenessMultiplier` | 2・3・5 / 0.9・1・1.1 / 0.8・1・1.2 | 難易度ごとの数・速さ・気づく距離(`docs/design/difficulty.md`) |

そのほかの `Prey...`(`PreyWanderPause...`、`PreyCalmRatio`、`PreyAbilityRollSeconds`、`PreySpawnZoneRatio` など)の意味は、`Config.luau` のコメントを見る。

## 部品の役割
| ファイル | 役割 |
|---|---|
| `Services/FarmerPlayer.luau` | プレイヤーを巨人にする(`Apply`)。ズーム距離を元に戻す(`Reset`)。実際の倍率を返す(`GetScale`) |
| `Services/PreyService.luau` | AIザリガニの、出現・動き・つかまえる判定・片づけ |
| `ServerStorage/Modules/FarmerModel.luau` | 麦わら帽子(`AddHat`)。農家さんAIとプレイヤーで共用 |
| `Services/RoundService.luau` | ラウンドの開始・終了。`OnRoundStart` / `OnRoundEnd` / `OnRestart` で、`PreyService` に知らせる。`NotifyAllPreyCaught` を受ける |
| `Services/ScoreService.luau` | 点数。`AddPoints`、やくわりごとの式(`calcScore`) |
| `Controllers/GuiController.luau` | 「のこり: N ひき」、やくわりごとの結果の文言、稲刈り機の予告(ザリガニのときだけ) |
| `Controllers/JetController.luau`・`DiveController.luau` | 農家さんのとき・メニューの間は、ボタン・キー・表示を出さない |
| `Controllers/LightingController.luau` | 農家さんのクリアでは、光を夕方へジャンプさせない(いまの進み具合のまま) |
| `Controllers/CrayfishAnimator.luau` | AIザリガニの足・はさみを動かす。速さは、速度と、位置の差の、大きいほう |

## 新しい動きを足すには(例: AIが、餌を食べに行く)
まず仕様書を書く(仕様書 016 の「作らないこと」にある)。状態は `PreyService.luau` の `PreyMode` と `thinkPrey` に足す。数字は `Config.luau` に足す。
