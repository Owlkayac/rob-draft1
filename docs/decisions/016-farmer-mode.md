# 決定 016: 農家さんになって、AIのザリガニをつかまえるモードを作る

- 日付: 2026-11-03
- 決めた人: 開発者(依頼)と、Claude(作り方の案)。仕様書は `docs/specs/016-farmer-mode.md`。仕組みの説明は `docs/design/farmer-mode.md`。
- 関連: 仕様書 015(メニューと難易度)で作った「やくわり」(`Crayfish` / `Farmer`)の土台に、`Farmer` の中身を入れた。

## 依頼
- 「天敵側をやるのも、選択してできるようにしたい」(開発者)。

## 決めたこと
- メニューで「農家さん」を選んで「スタート」を押すと、プレイヤーが**巨人の農家さん**になり、田んぼにいる**AIのザリガニ**を、時間内(300秒)にぜんぶつかまえるモードが始まる。
- **相手がAIなのは、最大プレイヤー数が 1 だから**(決定 002)。将来、複数人で遊べるようにしたら、ザリガニ側と農家さん側を、プレイヤーどうしで分ける(いまは、AIが、相手)。
- ぜんぶつかまえたら、すぐ「クリア」(ぜんいん つかまえた!)。時間切れは「にげられた…」(内部では `Caught`)。
- このモードでは、稲刈り機・餌・AIの農家さんは出ない。潜る・ジェットの操作と表示もない。

## 選んだ案(あとで変えられる)
- **プレイヤーのキャラクターを、`Model:ScaleTo` で巨人にする**(`FarmerPlayer.luau`)。外見はプレイヤーのアバターのまま、麦わら帽子だけ足す(農家さんAIと同じ帽子を `FarmerModel.AddHat` で公開して、使い回した)。
  - 服や髪が読み込まれるのを待ってから(最大 `FarmerPlayerAppearanceWaitSeconds` 秒)大きくする。先に大きくすると、あとから付く服の大きさが合わないおそれがあるため。その間(数秒)は、標準サイズのまま歩ける。
  - カメラのズーム距離(`Player.CameraMinZoomDistance` / `CameraMaxZoomDistance`)を 20 / 60 にする。メニューに戻る・ザリガニで始めるとき、元の値に戻す。巨人のキャラクター自体は、生まれ直すと新しいキャラクターになるので、戻す必要がない。
- **AIザリガニの見た目**: `CreateHumanoidModelFromDescription` で人型の土台を作り、`CrayfishModel.Attach` でザリガニの見た目をつけ、人型は隠す(プレイヤーのザリガニと同じ作り方)。土台は**最初に1つだけ**作って「見本」にし、あとは `Clone`(複製)で増やす。人型の作成は待ちが入るので、数ひきぶん待たないため。人型を作れなかったときは、`HumanoidRootPart` と `Humanoid` だけの簡易モデルで代わりにする。
  - 動きの計算はサーバー(`SetNetworkOwner(nil)`)。足・はさみ・ひげ・しっぽは、クライアントの `CrayfishAnimator` が、プレイヤーのザリガニと同じように動かす(`Workspace` の `CrayfishVisual` を拾う仕組みなので、そのまま動く)。
- **AIの動き**: 4つの状態(うろうろ / にげる / 潜る / ジェット)を、サーバーの1つのループ(`EnemyTickSeconds` ごと)で判断する。反応に 0.2〜0.5 秒のランダムな遅れを入れて、完璧には逃げない。出現から 3 秒は逃げない。壁ぎわでは壁にそって逃げ、角に追いつめられると動けない(つかまりやすい)。くわしくは `docs/design/farmer-mode.md`。
- **潜っていても、近ければつかまる**: 潜っていないとき `FarmerCatchDistance × 巨人の大きさ`(10)以下、潜っているとき `FarmerCatchHiddenDistance × 巨人の大きさ`(5)以下(仕様書 002・014 と同じ考え方)。判定はサーバー(`PreyService`)が、横方向(XZ)の距離で行う。
- **時間切れは `Caught` として扱う**: 画面の文言と点数の式が、やくわりで違うだけ。内部の状態の種類(`Playing` / `Caught` / `Cleared` / `Menu`)は増やさず、`RoundState` の形も変えていない。文言は、クライアントが Player の Attribute `Role` を見て選ぶ。
- **点数の式**(`ScoreService`): `つかまえた数 × PreyCatchPoints(100)`、クリアしたときは、さらに `のこり秒 × PreyTimeBonusPerSecond(1) + ClearBonus(100)`。最後に `ScoreMultiplier` を掛けて丸める。農家さんには「生き延びた秒数」の点は入らない。汎用の点を足す `ScoreService.AddPoints` を足し、`AddFood` はそれを使うようにした。ベスト記録は、`Farmer_Normal` のように、やくわり × なんいどで別に保存される(仕様書 015)。
- **ザリガニ専用の機能は、農家さんのときは出さない**:
  - 稲刈り機: `IsActive` に「やくわりが `Crayfish`」を足した。
  - 農家さんAI: これまで常に出ていた(`IsActive` なし)が、`IsActive`(ザリガニのやくわりで、ゲームを始めている間だけ)を持つ形にした。これで、農家さんモードとメニューの間は出ない。「もう一度」や「スタート」のたびに作り直される(作り直しのあいだ、1〜2秒いない)。
  - 餌: `FoodService` が、農家さんのラウンドでは置かない(0個)。
  - 潜る・ジェットの要求: `CrayfishService` が、やくわりが `Farmer` のとき無視する。画面のボタンとキーも、クライアントが出さない。
- **`RoundService` は `PreyService` を読み込まない**(循環 require を避ける)。代わりに、`RoundService.OnRoundStart` / `OnRoundEnd`(新しく足した)と既存の `OnRestart` に、`PreyService` が関数を登録する。AIは、スタート・もう一度・メニューへで、すべて消えて、必要なら出し直される。ラウンドが終わったら(結果の画面の間)も、消す。
- **クライアントへの知らせ**: 新しい RemoteEvent は足さず、Player の Attribute を使った。`Role`・`Difficulty`(`SetupService` が、スタートが通ったときに設定)と `PreyRemaining`(`PreyService` が設定)。

## 見直す時期
- 簡単すぎる・難しすぎる: `Config.luau` の `Prey...`(速さ・気づく距離・潜る/ジェットの確率とため直し)と、`Difficulties` の `PreyCount` などを調整する(調整のしかたは `docs/design/farmer-mode.md`)。
- AIの動きが、不自然・単調: 反応の遅れ、うろうろの立ち止まり、逃げる1回の距離(`PreyFleeStepStuds`)を調整する。
- 複数人で遊べるようにしたとき: ザリガニ側と農家さん側を、プレイヤーどうしで分ける。AIは、人数が足りないときの補いにできる(`PreyService` の、Player をキーにした表は、そのための準備)。

## 作ってみて気をつけたこと
- 農家さんAI(`Farmer` 定義)を `IsActive` 化したので、ザリガニのモードでも、ラウンドが始まってから農家さんが現れるまで、人型の作成の待ち(1〜2秒)がある。出現直後の猶予(3秒)は、作られたときから数える。
- 結果の画面の間(`Caught` / `Cleared`)も、フェーズは `Playing` のままなので、農家さんAIは、そのまま残る(「メニューへ」で消える)。

## レビュー後の調整(2026-11-03)
レビューの指摘のうち、016 に関わるものを直した(015 のぶんは `docs/decisions/015-menu-and-difficulty.md` の同じ名前の節)。
- **全員が「壊れた」ときに、つかまえていないのにクリアになる問題**(`PreyService`): 壊れた個体は、「つかまえた」扱いにしない。見本から複製して、出現範囲のランダムな位置に、出し直す(`createPrey` を再利用)。出し直せなければ、数から外す(警告は1回だけ)。のこりが 0 になったとき、つかまえた数(`Session.CaughtCount`)が 0 なら、`Cleared` にせず、`Caught`(「にげられた…」)で終える。1 以上なら、これまでどおり `Cleared`。
- **AIザリガニの足・はさみが止まって見えるおそれ**(`CrayfishAnimator`): 速さを、`AssemblyLinearVelocity` と「前のフレームとの位置の差 ÷ dt」(水平)の、大きいほうにした。`FarmerMaxPlausibleSpeed` を超える位置の差は、テレポートとみなして無視する(`EnemyPresenceController` と同じ)。前の位置は、エントリごとに持つ。
- **AIザリガニどうしが、ぶつかって止まる問題**: 衝突グループ `"Prey"` を作り(`PhysicsService`。登録済みでもエラーにならないよう `pcall`)、`"Prey"` どうしは衝突しない。AIの全部品を `"Prey"` にする。床(`Default`)とは、衝突したまま。人型は `CanCollide` を `true` に戻すことがあるので、`CanCollide = false` だけでは足りず、グループで防ぐ。
- **見本を作れなかったとき**: 見本づくりをあと1回だけやり直し、それでも作れなければ、ラウンドを `Caught`(つかまえた数 0)で、すぐ終わらせる(`RoundService.NotifyCaught`)。1ぴきも作れなかったときも、同じ。
- **農家さんAIの猶予**: ラウンドが始まるたびに、やり直す(015 の節も参照)。
- **農家さんモードで、クリアしたとき、光が夕方へジャンプする**(`LightingController`): `Role` が `Farmer` のときは、`Cleared` でも進み具合を変えない(`Caught` と同じ)。ザリガニの `Cleared`(夕焼けが最大)は、そのまま。
- **`FarmerPlayer` の服の読み込み待ち**: 終わりの条件に、`player.CharacterAppearanceLoaded`(そのキャラクターのもの)も足した(`HasAppearanceLoaded` と、どちらか早いほう。最大の待ち時間は、そのまま)。
- **小さな整理**: `WarnOnce` のキーを、メッセージ全文ではなく、固定の文字列(`"PreyThink"`・`"PreyUpdate"`)にした(エラーの文が変わるたびに、警告が出続けるのを防ぐ)。使われていなかった `PreyService.GetRemaining` を消した。
- **ドキュメント**: 仕様書 016 の「専用の扱い」を、「`Caught` として扱う」に直した。`docs/design/farmer-mode.md` も直した。
