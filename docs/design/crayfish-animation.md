# ザリガニの足の動きのしくみと調整(初心者向け)

仕様書: `docs/specs/010-crayfish-animation.md`。部品: `src/ServerStorage/Modules/CrayfishModel.luau`(関節を作る)、`src/StarterPlayer/StarterPlayerScripts/Controllers/CrayfishAnimator.luau`(動かす)

## どう動くか
1. サーバー(CrayfishModel)は、足・はさみ・ひげを、胴体に **Motor6D(関節。ドアのちょうつがいのようなもの)** でつなぐ。足の付け根などが、回転の中心になる。
2. クライアントの CrayfishAnimator は、見えているすべての `CrayfishVisual` を探し、毎フレーム、関節の `Transform`(回し具合)を書く。`Transform` は、自分の端末だけに効く(サーバーには届かない)。
3. 歩いた距離に合わせて足がふれる。速く歩くほど速く動き、止まると止まる。止まっているときは、はさみがゆっくりゆれ、ひげがときどきふるえる。
4. 潜っている間(`Hidden`)は、動かさない。

## Config の調整
| 名前 | 意味 | 調整のめやす |
|---|---|---|
| CrayfishLegSwingDeg | 足のふり(度) | 大きいと大股、小さいと細かい。足が交差して見えるときは、`CrayfishLegSwingDeg` を下げる |
| CrayfishLegCyclesPerStud | 1スタッドあたりの足の回数 | 大きいと足が速く見える |
| CrayfishClawBobDeg / CrayfishIdleClawDeg | はさみの上下(歩き / 止まり) | |
| CrayfishAntennaWagDeg / WagHz / WagGapSeconds | ひげのふるえの大きさ・速さ・間隔 | |
| CrayfishAntennaTrailDeg | 歩くときのひげのたなびき | |
| CrayfishIdleBreathSeconds | 止まっているときの周期(秒) | 0 にしない |
| CrayfishClawBobPerCycle | 足の1周期のあいだに、はさみが上下する回数 | 整数にする(小数だと動きが飛ぶ) |

## 新しい動く部品の足し方
1. CrayfishModel で、部品を `addPart` で作り、`addMotor(ctx, 部品, "名前", 関節の位置)` でつなぐ(動かさないなら `addFixedPart`)。Motor6D は胴体の子になる。
2. 名前の決まり(`LegL1`、`ClawL`、`AntennaL` など)に合わせると、CrayfishAnimator が見つける。新しい種類なら、`classifyMotor` と、動かす関数を足す。
3. 潜るときの半透明は、`CrayfishVisual` の中のすべての Part が対象なので、何もしなくてよい。
