# 光と空気のしくみと調整(初心者向け)

仕様書: `docs/specs/007-rice-and-atmosphere.md` の 4。部品: `src/StarterPlayer/StarterPlayerScripts/Controllers/LightingController.luau`

## どう動くか
1. サーバーが、1秒ごとに RoundState(状態、段階の名前、残り秒数)を送る(新しい通信は足していない)。
2. クライアントの LightingController が、**進み具合**(0=朝、1=夕方)を計算する。`1 - 残り秒数 / RoundSeconds`。クリアのときは 1、捕まったときはそのまま止まる。
3. 進み具合は1秒ごとにしか届かないので、そのまま使うと階段のように変わる。そこで毎フレーム、いまの値を目標へ**なめらかに近づける**(補間)。
4. 補間した値で、Lighting(時刻、明るさ)と、効果(Atmosphere=もや、ColorCorrection=色補正、Bloom=にじみ、SunRays=光の筋)を変える。
5. 「もう一度」で進み具合が大きく下がると、約0.5秒で朝へ戻る。
6. 進み具合の変化が `LightUpdateEpsilon`(0.0005 = 0.05%)より小さい間は、何も代入しない(軽くするため)。値を大きくすると軽くなるが、変化が少しカクつく。

すべて自分の端末だけの変化で、他のプレイヤーやサーバーには影響しない。

## 元からある効果の扱い
Studio のテンプレートは、最初から Lighting の下に Atmosphere や Bloom などを持っていることがある。同じ種類を2つ置くと見た目が二重にかかるので、次の順で探す。
1. `FieldAtmosphere` などの、このゲームの名前で探す。
2. なければ、**同じ種類の最初の1つ**を探して、それを使う。このとき元の値を覚えておき、`Stop()` で元に戻す(消さない)。
3. どちらもなければ、名前をつけて作る。自分で作ったものだけ、`Stop()` で消す。
(使うときは、元が無効(Enabled が false)でも有効にする。値は光の進み具合に合わせて上書きされる。)

## 調整のしかた(`Config.luau` の `Light...` と時刻)
どの項目も `...Morning`(朝)と `...Evening`(夕方)の2つの値があり、その間を進み具合で動く。

| 変えたいこと | 数字 | 効果 |
|---|---|---|
| 時刻の幅 | `ClockTimeStart` / `ClockTimeEnd` | 空の色と太陽の位置 |
| 霧が濃すぎる | `LightAtmoDensity...` を下げる | もやが薄くなる |
| 遠くがぼやけすぎる | `LightAtmoHaze...` を下げる | 遠景のかすみが減る |
| 夕方の金色の強さ | `LightAtmoColorEvening`、`LightAtmoGlareEvening` | もやの色、太陽まわりのまぶしさ |
| まぶしい | `LightBloomIntensity...`、`LightBrightness...`、`LightSunRaysIntensity...` を下げる | 光のにじみ、全体の明るさ、光の筋が弱くなる |
| 夕方を暖かく | `LightColorTintEvening`、`LightColorSaturationEvening` | 画面全体の色合い |
| 変化が遅い・速い | `LightSmoothRate`(大きいほど速い) | 目標への追いつき方 |
| 朝へ戻る速さ | `LightResetRate` | 「もう一度」のときの戻り方 |
| 更新を減らして軽くする | `LightUpdateEpsilon`(0.0005) | 大きいほど更新が減って軽い。大きすぎると変化がカクつく |

重いと感じたら、まず Bloom と SunRays の Intensity を 0 にして試す。
