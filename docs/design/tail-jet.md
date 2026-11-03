# 尻尾のジェットのしくみと調整(初心者向け)

仕様書: `docs/specs/013-tail-jet.md`

## 何をするか
Q キー(スマホは「ジェット」ボタン)を押すと、0.8秒のあいだ、2.4倍の速さで、まっすぐ前に進む。そのあと8秒は使えない。

## しくみ(流れ)
1. 押すと、クライアント(`JetController`)が、サーバーに「ジェットしたい」とお願い(`JetRequest`)を送る。
2. サーバー(`CrayfishService`)が、使えるか確かめる(生きている・潜っていない・噴射中でない・ため直しが終わっている)。OKなら、歩く速さを2.4倍にして、キャラクターに「噴射中」の目印(Attribute `Jetting`)をつける。
3. 目印を見て、自分の端末が、(a) 発動の瞬間の向きに進み続ける、(b) 視野を広げる、(c) 尻尾を丸める、(d) 音を鳴らす。粒子(`JetEmitter`)は、サーバーが出す。粒子は、胴体につけた見えない小さな部品 `JetNozzle`(尻尾の先の少し後ろ)の中にある。
4. 0.8秒たつと、サーバーが速さを戻す。使えるようになる時刻を `JetReadyTime` として知らせ、画面の下の表示(`JetGui`)が残り時間を出す。

速さや判定は、サーバーが決める。クライアントのお願いは、そのまま信用しない。

## 調整のしかた(`Config.luau`)
| 変えたいこと | 数字 |
|---|---|
| 強すぎる・弱すぎる | `JetSeconds`(長さ)、`JetSpeedMultiplier`(倍率)、`JetCooldownSeconds`(ため直し) |
| 視野の広がり | `JetFovAdd`(度)、`JetFovInSeconds`、`JetFovOutSeconds` |
| 尻尾の丸め方 | `CrayfishTailCurlDeg`(角度。初期値45)、`...InSeconds`、`...HoldSeconds`、`...ReleaseSeconds`(3つの合計は `JetSeconds` 以下に) |
| 画面の表示 | `JetGuiUpdateSeconds`(更新間隔。0 にしない) |
| 粒子 | `JetRate`(多すぎ・重いときは下げる)、`JetLifetimeMin/Max`、`JetSpeedMin/Max`、`JetSizeStart/End`、`JetColor`、`JetSpreadAngle` |
| 音 | `SoundIds.Jet`(ID)、`SoundVolumes.Jet`(音量) |

注意: `CrayfishTailCurlInSeconds` と `CrayfishTailReleaseSeconds` は、0 にしない(0 で割る計算があるため。コード側でも、0.001 より小さくならないようにしてある)。
