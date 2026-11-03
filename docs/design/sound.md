# 音のしくみと、鳴らし方(初心者向け)

仕様書: `docs/specs/011-sound.md`

## いまの状態
**音の素材(ID)は、まだ何も入れていない。** なので、いまは、ゲームは無音のまま。エラーも警告も出ない。
ID を入れると、その音だけが鳴り始める。

## 音の一覧
| 名前 | いつ鳴るか | 鳴らす場所 |
|---|---|---|
| `Ambient` | ゲーム中ずっと(くり返し)。つかまった・クリアのときは小さくなり、「もう一度」で戻る | 各自の端末(`SoundController`) |
| `HarvesterEngine` | 稲刈り機が動いている間(近いほど大きい) | 稲刈り機のモデルの中(`EngineSound`。サーバーが作る) |
| `Splash` | 潜る・浮上するとき(`Hidden` が実際に変わったときだけ。2D。自分の端末で、自分のザリガニの音を鳴らすため) | 各自の端末 |
| `Jet` | ジェットを噴射し始めたとき(`Jetting` が false から true に変わったときだけ、1回。仕様書 013) | 各自の端末 |
| `Eat` | 餌を食べたとき(仕様書 012 でつないだ。`SoundController.PlayEat()`) | 各自の端末 |
| `Caught` | つかまったとき(1回だけ) | 各自の端末 |
| `Clear` | クリアしたとき(1回だけ) | 各自の端末 |
| `FarmerNoticed` | 農家さんが `Notice`(気づく)に変わった瞬間(1回。3D。仕様書 014) | 農家さんの `HumanoidRootPart` の下(`EnemyPresenceController` が作る) |
| `FarmerStep` | 農家さんの足が地面につくたび(3D。遠いと小さい。`FarmerStepRollOffMin/Max`。仕様書 014) | 農家さんの `HumanoidRootPart` の下 |
| `Heartbeat` | 農家さんが `Notice`・`Chase` で近いあいだ(くり返し。近いほど大きい。`FarmerHeartbeat...`。仕様書 014) | 各自の端末(`SoundService`) |

## 鳴らすまでの手順
1. Roblox の **Creator Store**(クリエイターストア。みんなが作った素材を探せる場所)を開き、種類を「オーディオ」にして、使ってよい音を探す。
   - 自分で作った音をアップロードしてもよい。
   - 使っていい条件(ライセンス)を、必ず読む。分からない音は、使わない。
2. 音のページの **ID(数字)** をコピーする。
3. `src/ReplicatedStorage/Shared/Config.luau` の `SoundIds` に、`"rbxassetid://数字"` の形で貼る。例: `Ambient = "rbxassetid://123456789",`(この数字は例。本物のIDではない)
4. `assets/CREDITS.md` の「音の台帳」に、音の種類・ID・素材の名前・出どころ(URL)・使用条件・確認した日を書く。
5. Studio で遊んで、鳴るか確かめる。

## 音量の調整
- `Config.luau` の `SoundVolumes`(0〜1。大きいほど大きい音)。種類ごとに変えられる。
- 稲刈り機の音が届く距離: `SoundHarvesterRollOffMaxDistance`(これより遠いと聞こえない)、`SoundHarvesterRollOffMinDistance`(この近さまでは、小さくならない)。
- つかまった・クリアのときの環境音の大きさ: `SoundAmbientDuckVolume`。小さくなる・戻る時間: `SoundAmbientDuckSeconds`(秒)。

## うまくいかないとき
- **音が鳴らない**: ID の形を見る。`rbxassetid://` のあとが、数字だけになっているか(空白や文字、`https://` が入っていないか)。形が違うと、Output(出力)に警告が1回出て、その音は鳴らない。
- **形は合っているのに鳴らない**: その音が、あなたのゲームで使える設定(公開されている・自分のものか、使用が許可されている)か確かめる。Creator Store の音は、使える設定のものを選ぶ。
- **うるさい・小さい**: `SoundVolumes` を変える。
- **稲刈り機の音が聞こえない**: 稲刈り機が出てくる(出穂の段階)まで待つ。近づくほど大きくなる。`SoundHarvesterRollOffMaxDistance` が小さすぎないか見る。
- 外部のURLは、安全のため、受けつけない。
