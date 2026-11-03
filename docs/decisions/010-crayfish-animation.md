# 決定 010: ザリガニの足の動き(アニメーション)

- 日付: 2026-11-03
- 決めた人: 開発者(「全て番号順に実装」という依頼のうちの1つ。決定007の「次の質感の候補」3番)。仕様書は `docs/specs/010-crayfish-animation.md`。

## 依頼
ザリガニが歩くと足が動き、はさみとひげも生き物らしく動くようにする。

## 決めたこと
- 動きは、**クライアント(各自の端末)だけ**で動かす。サーバーの負担も通信も増やさない(新しい RemoteEvent は足さない)。
- 動かす部品は **Motor6D(関節)** でつなぐ。動かさない部品は、これまでどおり WeldConstraint。
- 外部のアニメーション素材は使わない。数字は `Config.luau`(`Crayfish...`)にまとめる。

## Claudeが選んだ案(あとで変えられる)
- **動かす部品**: 足(左右3本ずつ。`LegL1`〜`LegR3`)、はさみ(`ClawL`、`ClawR`。腕に関節をつけ、球と先の箱は腕に溶接して、一緒に動く)、ひげ(`AntennaL`、`AntennaR`)。しっぽは動かさない(任意だったので、見送り)。
- **関節の位置**: 足は付け根、はさみは腕の後ろ端、ひげは根元。関節の向きは、ザリガニの向きに合わせた(X=右、Y=上、Z=後ろ)。`C0` と `C1` は、「今の部品の位置から計算」するので、動かさないときの見た目は、溶接のときと同じ。
- **足**: Y軸まわりに前後にふる。隣の足、左右の足は互い違い(交互)。位相は「歩いた距離」に比例して進むので、速いほど速く、止まると止まる。
- **速さ**: `HumanoidRootPart.AssemblyLinearVelocity` の水平成分だけ使う(`MoveDirection` は使わない。他のプレイヤーでも同じ方法で動くため)。
- **潜っている間は止める**: キャラクターの Attribute `Hidden` が true の間は Transform を更新せず、姿勢を保つ。
- 歩く・止まるの切り替えは、`CrayfishAnimBlendPerSecond` でなめらかにつなぐ(急に切り替わらない)。
- 見えなくなった(消えた、離れた)キャラクターは、表と接続から片付ける。

## 見直す時期
- 動きが大きい・小さい・不自然なとき: `Config.luau` の数字を調整する(`docs/design/crayfish-animation.md`)。
- しっぽのゆれ、潜るときに沈む動きなどは、まだ作らない。

## レビュー後の調整(2026-11-03)
7. **死んだとき**: `Humanoid.BreakJointsOnDeath = false` にして、関節(Motor6D)が壊れて、足・はさみ・ひげがばらばらに落ちないようにした(`CrayfishService`)。
8. **0 で割らない**: `CrayfishIdleBreathSeconds`、`CrayfishAntennaWagGapSeconds` は、コード側で小さな正の数に直して使う。`CrayfishClawBobPerCycle` は整数にする(Config のコメントに記載)。
9. **足の間隔と振り幅**: 今は変えない。足が交差して見えるときは `CrayfishLegSwingDeg` を下げる(`docs/design/crayfish-animation.md`)。
- 起動: `Main.client.luau` は、各部品を `task.spawn` と `pcall` で独立して起動する(1つが止まっても、ほかは起動する)。
