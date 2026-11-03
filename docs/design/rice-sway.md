# 風で稲がゆれるしくみと調整(初心者向け)

仕様書: `docs/specs/008-rice-sway.md`。部品: `src/StarterPlayer/StarterPlayerScripts/Controllers/RiceSwayController.luau`

## どう動くか
1. サーバー(FieldService)は、稲を1株ごとに Folder(`Plant_ix_iz`)に入れる。Folder には、根もとの位置 `Root` と、刈られたか `Cut` が、メモとして(Attribute)ついている。
2. クライアントの RiceSwayController は、自分のキャラクターから `RiceSwayRadius` 以内の株だけを選ぶ。
3. 選んだ株を、根もとを中心に、風下へ小さく傾ける。傾きは「0〜最大」の間で、風下に傾いて戻る(風上へは傾かない)。株の位置によってゆれるタイミングがずれ、波の山が風下へ流れて見える。式は「`RiceSwayMaxDeg` × 強風の強弱 × (0.5 + 0.5 × sin(波 - 位相))」。位相は風下の株ほど大きく、`波 - 位相` の符号が逆だと、波が風上へ流れて見えてしまう。ときどき風が強くなり、風の向きも少しふらつく。
4. 範囲の外に出た株は、元の位置に戻す。刈られた株と、まだ見えない部品(出穂の前の穂)はゆらさない。範囲の外の株では、`Cut` も読まない(軽くするため)。
5. 更新は1秒に `RiceSwayHz` 回だけ。

ゆれは、自分の端末だけの見た目。他のプレイヤーやサーバーには関係ない。

## 元の位置の覚え直し
稲が育つと、サーバーが部品の位置を変える。クライアントは「自分が最後に書いた位置」を覚えていて、いまの位置がそれと大きく違えば「サーバーが変えた」とみなし、そこを新しい元の位置にする。だから、育ったあとも、ずれが残らない。

## 調整のしかた(`Config.luau` の `RiceSway...` と `RiceWind...`)
| 変えたいこと | 数字 | 効果 |
|---|---|---|
| 重い | `RiceSwayRadius` を小さく、`RiceSwayHz` を下げる | ゆらす株が減る、更新が減る(下げすぎるとカクつく) |
| ゆれが大きい・小さい | `RiceSwayMaxDeg` | 傾きの最大(度) |
| ゆれが速い・遅い | `RiceSwayPeriodSeconds` | 1回のゆれの時間(大きいほど遅い) |
| 風の向き | `RiceWindDirectionDeg` | 0度 = +Z の向き、90度 = +X の向き |
| 波の細かさ | `RiceWindWaveLength` | 小さいほど、波が細かい(0 にしない) |
| 強風の強弱 | `RiceWindGustMin` / `RiceWindGustMax` / `RiceWindGustPeriodSeconds` | 弱いときと強いときの割合、変わる速さ |
| 風向きのふらつき | `RiceWindDirWobbleDeg` | 0 にすると、ふらつかない |
