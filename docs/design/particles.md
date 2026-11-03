# 粒子のしくみと調整(初心者向け)

仕様書: `docs/specs/009-particles.md`

## 粒子とは
ParticleEmitter(パーティクルエミッター)は、小さな点や煙のようなものを、たくさん自動で出す部品。Part につけて使う。画像は、Roblox の標準のものを使っている。

## どこにあるか
| 名前 | つけた場所 | いつ出るか |
|---|---|---|
| `ChaffEmitter`(刈りくず) | 稲刈り機の刃の前の上の角にある Attachment `ChaffSource`(前と上の間に傾けてある) | 稲刈り機が実際に進んでいる間 |
| `DustEmitter`(土ぼこり) | 稲刈り機の後ろの見えない箱 `DustSource` | 同上 |
| `SplashEmitter`(水しぶき) | ザリガニの胴体 | 潜る・浮上のとき、0.25秒だけ |

粒子は `Enabled`(出す・出さない)を切り替えるだけ。毎回、新しく作らない。サーバーで `Emit()` を呼ぶと他の端末には見えないので、`Enabled` を使っている。

## 調整のしかた(`Config.luau`)
| 変えたいこと | 数字 |
|---|---|
| 重い・多すぎる | `HarvesterChaffRate`、`HarvesterDustRate`、`SplashRate`(1秒に出す数)を下げる |
| 遠くまで飛ぶ | `...SpeedMin` / `...SpeedMax` |
| 長く残る | `...LifetimeMin` / `...LifetimeMax`(秒) |
| 大きさ | `...SizeStart`(出たとき)と `...SizeEnd`(消える直前) |
| 色 | `HarvesterChaffColorStart/End`、`HarvesterDustColor`、`SplashColor` |
| 広がり | `...SpreadAngle`(度。大きいほど広がる) |
| 落ちる強さ | `...Acceleration`(Y が負なら下へ落ちる。刈りくずは強いとすぐ床の下へ落ちるので、-12 くらいの弱めにしてある) |
| 刈りくずの上向きの強さ | `HarvesterChaffUpwardRatio`(前向きを 1 としたときの割合。0 で真っ直ぐ前) |
| 水しぶきの長さ | `SplashBurstSeconds`(秒) |

数字を変えたら、Studio で遊んで見て確かめる。
