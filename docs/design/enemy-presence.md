# 巨人の迫力(歩き・足音の揺れ・緊張)の説明書

初心者向けの説明です。仕様書 `docs/specs/014-enemy-presence.md` の 3 に対応します。
部品は `src/StarterPlayer/StarterPlayerScripts/Controllers/EnemyPresenceController.luau`(クライアント専用)。
**画面と音だけの演出**で、勝ち負けや当たり判定には関係しません(判定はサーバー)。

## 用語
- **Motor6D(関節)**: 体の部品どうしをつなぐ関節。`Transform` に回転を入れると、その関節が曲がる。
- **位相**: 歩きの動きが「いま周期のどのあたりか」を表す角度。歩いた距離に比例して進む。
- **CameraOffset**: カメラの位置を、キャラクターからずらす設定。上下にずらすと、画面が揺れる。
- **ColorCorrectionEffect**: 画面全体の色を変える効果(色合い・彩度・明るさ)。

## しくみ
| 演出 | どう動くか |
|---|---|
| 巨人の歩き | 農家さんの足・膝・腕・腰・首の関節を、毎フレーム動かす。歩いた距離で動きが進むので、速いほど速く動き、止まると止まる。関節が見つからない簡易モデルは、何もしない |
| `Notice` | 腕を前に持ち上げる |
| `Search` | 首を左右にふる(きょろきょろ) |
| 止まっているとき | 体がゆっくり前後にゆれる(息づかい) |
| 足音の揺れ | 足が地面につくたびに、自分のカメラが上下にはねて、すぐ戻る。近いほど強く、遠い(60スタッド超)と揺れない |
| 足音・気づいた音 | 音の ID を入れたときだけ、農家さんの位置から3Dで鳴る(`docs/design/sound.md`) |
| 近づく緊張 | `Notice`・`Chase` の農家さんが45スタッド以内に近づくと、画面が赤く・暗く・鮮やかになる。離れると、なめらかに戻る |
| 心臓の音 | ID を入れたときだけ。緊張しているあいだ、くり返し鳴る |

## 調整のしかた(`src/ReplicatedStorage/Shared/Config.luau`)
| 気になること | 変える数字 |
|---|---|
| 足の動きが速すぎる・遅すぎる / 足音の間隔 | `FarmerStrideStuds`(大きいほどゆっくり) |
| 足・腕・膝のふりが大きすぎる・小さすぎる | `FarmerLegSwingDeg`、`FarmerArmSwingDeg`、`FarmerKneeBendDeg` |
| 体の上下 | `FarmerBobStuds` |
| 止まる・歩く切り替えが急 / ゆるい | `FarmerAnimBlendPerSecond` |
| 気づいたときの腕の上がり | `FarmerNoticeArmRaiseDeg` |
| 探すときの首のふり | `FarmerSearchNeckSwingDeg`、`FarmerSearchNeckHz` |
| 揺れが強すぎる・弱すぎる | `FarmerShakeMaxOffset`(最大のはね) |
| 揺れが長引く・すぐ消える | `FarmerShakeDecaySeconds`(小さいほどすぐ戻る) |
| 揺れる距離 | `FarmerShakeMaxDistance` |
| 画面が暗すぎる・赤すぎる | `FarmerThreatBrightness`(0 に近づけると明るい)、`FarmerThreatTint`、`FarmerThreatSaturation` |
| 緊張が始まる距離 | `FarmerThreatMaxDistance` |
| 緊張の変わる速さ | `FarmerThreatSmoothRate` |
| 心臓の音の大きさ | `SoundVolumes.Heartbeat`、`FarmerHeartbeatMinVolumeRatio` |
| 足音が届く距離 | `FarmerStepRollOffMin`、`FarmerStepRollOffMax` |

「時間」「距離」で割る数字(`FarmerStrideStuds`、`FarmerShakeMaxDistance`、`FarmerShakeDecaySeconds`、`FarmerThreatMaxDistance`、`FarmerIdleBreathSeconds`)は、0 にしない。

## うまくいかないとき
- **農家さんの足が動かない**: 簡易モデル(Part だけ)になっていないか。Output に「簡易モデルを使います」の警告が出ていると、関節がないので動かない。
- **揺れない**: 農家さんが `FarmerShakeMaxDistance` より遠くにいないか。歩いていないとき(`Notice` など)は、足音も出ない。
- **画面の色が戻らない**: Lighting の中の `FieldThreatColorCorrection` の値を見る。農家さんが `Search`・`Patrol` なら、数秒で戻る。
