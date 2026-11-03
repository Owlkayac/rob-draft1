--!strict
-- ゲームの設定値(価格、時間、確率など)はここにまとめる。
-- コードの中に数字を直書きしない。

local Config = {
	GameName = "Untitled",

	-- ザリガニの操作(仕様書 001)。数字は仮の初期値で、遊びながら調整する。
	CrayfishWalkSpeed = 16, -- 歩く速さ
	DiveMaxSeconds = 3, -- 連続で潜れる最大の時間(秒)
	DiveCooldownSeconds = 5, -- 浮上してから、次に潜れるまでの時間(秒)
	DiveRequestMinInterval = 0.2, -- 潜る操作の受け付け間隔の最小値(秒)。連打対策

	DiveRemoteName = "DiveRequest", -- 潜る/やめるのお願いを送る RemoteEvent の名前
	DiveTransparency = 0.6, -- 潜っている間の透明度(0=見える、1=完全に透明)
	-- ザリガニの見た目(仕様書 005)。細かい寸法は CrayfishModel の中にある
	CrayfishColor = Color3.fromRGB(200, 40, 30), -- ザリガニの体の色(赤)
	CrayfishBellyColor = Color3.fromRGB(240, 110, 60), -- お腹・足・ひげの色(明るいオレンジ)
	CrayfishEyeColor = Color3.fromRGB(15, 15, 15), -- 目の色(黒)
	CrayfishBodyLength = 4.5, -- 全長の目安(スタッド)
	CrayfishBodyHeight = 1.6, -- 高さの目安(スタッド)
	CrayfishGroundOffset = 0, -- 地面の高さの調整値(0 で計算どおり。プラスで上、マイナスで下)

	-- ザリガニの足の動き(仕様書 010)。クライアントだけで動かす。動きが大きい・小さいときは、ここの数字を調整する
	CrayfishLegSwingDeg = 28, -- 足のふりの大きさ(度)
	CrayfishLegCyclesPerStud = 0.35, -- 1スタッド歩くときの、足の動きの回数(0.35 は、約2.9スタッドで足が1往復)
	CrayfishLegPhaseStep = math.pi, -- 同じ側の、隣の足との位相のずれ(ラジアン。pi で互い違い)
	CrayfishClawBobDeg = 6, -- 歩くときの、はさみの上下の大きさ(度)
	CrayfishClawBobPerCycle = 2, -- 足の1周期のあいだに、はさみが上下する回数。整数にする(小数だと、位相が一周するところで動きが飛ぶ)
	CrayfishIdleBreathSeconds = 2.4, -- 止まっているときの、ゆっくりした動き(呼吸)の周期(秒)。0 にしない(0 で割るため)
	CrayfishIdleClawDeg = 3, -- 止まっているときの、はさみのゆれの大きさ(度)
	CrayfishAntennaWagDeg = 10, -- 止まっているときの、ひげのふるえの大きさ(度)
	CrayfishAntennaWagHz = 6, -- ひげのふるえの速さ(1秒あたりの回数)
	CrayfishAntennaWagGapSeconds = 3.5, -- ひげがふるえる間隔(秒。この間隔ごとに少しふるえる)。0 にしない(0 で割るため)
	CrayfishAntennaTrailDeg = 12, -- 歩くときに、ひげが後ろ(下向き)にたなびく角度(度)
	CrayfishMoveMinSpeed = 0.5, -- この速さ(スタッド/秒)より遅いときは、止まっているとみなす
	CrayfishAnimBlendPerSecond = 8, -- 歩く・止まるの切り替えのなめらかさ(大きいほど素早く切り替わる)

	-- 田んぼの舞台(仕様書 004)。数字は仮の初期値。
	FieldSize = 120, -- 田んぼの一辺の長さ
	FieldWallHeight = 8, -- あぜ(壁)の高さ
	FieldWallThickness = 2, -- あぜの厚さ
	FieldFloorThickness = 1, -- ゆかの厚さ
	FieldFloorTopY = 0.5, -- ゆかの上面の高さ(Baseplate の上面は y=0)
	RiceSpacing = 6, -- 稲の株と株の間隔(仕様書 007 で 8 から変更。重いと感じたら 8 に戻す)
	SpawnSize = 6, -- スタート地点の一辺の長さ
	SpawnEdgeOffset = 3, -- スタート地点を、南の端からどれだけ内側に置くか
	PatrolPointHeight = 3, -- 見回り地点の、ゆかの上面からの高さ(歩ける高さ)
	PatrolPointRatio = 0.25, -- 見回り地点の位置(田んぼの一辺に対する割合。中心から±この割合)

	-- 稲の成長とクリア(仕様書 003)
	RoundSeconds = 300, -- 1回の長さ(稲刈りの日までの時間・秒)
	-- 段階2・3に切り替わる経過時間(秒)。
	-- 3つめ(出穂の始まり)は、稲刈り機(仕様書 006)が走り切る時間から決める:
	--   経路の長さ ÷ HarvesterSpeed + HarvesterEntryDelaySeconds < RoundSeconds - 出穂の始まり
	--   (約1500 ÷ 13 ≒ 117秒 + 3秒 = 120秒 < 300 - 170 = 130秒)。速さ・幅を変えたら、ここも見直す
	GrowthStageSeconds = { 75, 170 },
	SightMultipliers = { 1.0, 0.8, 0.6 }, -- 段階ごとの、天敵の発見距離の倍率
	StageNames = { "田植え", "成長", "出穂", "稲刈りの日" }, -- 段階の名前
	CharacterWaitSeconds = 10, -- キャラクターの Humanoid が現れるのを待つ最大の時間(秒)
	RoundTickSeconds = 1, -- ラウンドの時間チェックと通知の間隔(秒)
	RespawnBlockSeconds = 100000, -- 死んだあとの自動復活を事実上止める時間(「もう一度」で復活させる)

	-- 通信の名前
	RoundStateRemoteName = "RoundState", -- サーバー→クライアント:状態・段階名・残り秒数
	RestartRemoteName = "RestartRequest", -- クライアント→サーバー:「もう一度」のお願い
	RestartRequestMinInterval = 1, -- 「もう一度」の受け付け間隔の最小値(秒)

	-- 天敵「農家さん」(仕様書 002)。数字は仮の初期値で、遊びながら調整する。
	-- 「距離」の数字は「標準サイズ(倍率1.0)基準」。実際に使うときは × FarmerScale する(仕様書 002 の 8)
	FarmerScale = 2.5, -- 農家さんの大きさの倍率(標準の人型の何倍か)
	FarmerSpeedMultiplier = 1.0, -- 歩く速さにかける倍率。大きさに比例させると追いつけなくなるので、いまは 1.0
	FarmerWalkSpeed = 12, -- 見回り中の速さ(× FarmerSpeedMultiplier)
	FarmerChaseSpeed = 15, -- 追跡中の速さ。ザリガニの歩く速さ16より少し遅い(× FarmerSpeedMultiplier)
	FarmerSightDistance = 30, -- 発見できる距離。大きさの倍率はかけない(稲の成長で倍率がかかる)
	FarmerCatchDistance = 4, -- 捕まえる距離(潜っていないとき。標準サイズ基準)
	FarmerCatchHiddenDistance = 2, -- 捕まえる距離(潜っているとき。標準サイズ基準。仕様書 002 の 9)
	FarmerLoseSightSeconds = 4, -- 見失ってから、見回りに戻るまでの時間(秒)
	FarmerSearchSeconds = 3, -- 潜った場所を探す時間(秒)
	FarmerSpawnMargin = 0.2, -- 出現位置の高さの余裕(ゆかにめり込まないように、少しだけ上に置く)
	EnemyTickSeconds = 0.2, -- 動きの判断をする間隔(秒)
	EnemyRepathSeconds = 0.5, -- 経路を作り直す間隔(秒)
	PatrolArriveDistance = 4, -- 見回り地点などに「着いた」とみなす距離(標準サイズ基準)
	WaypointReachDistance = 3, -- 経路の途中の点に「着いた」とみなす距離(標準サイズ基準)
	PathAgentRadius = 2, -- 経路探索で使う、体の半径(標準サイズ基準)
	PathAgentHeight = 5, -- 経路探索で使う、体の高さ(標準サイズ基準)

	-- 天敵「稲刈り機」(仕様書 006)。数字は仮の初期値で、遊びながら調整する。
	HarvesterSpeed = 13, -- 進む速さ。ザリガニの歩く速さ16より遅い
	HarvesterWidth = 14, -- 刈る幅(進行方向と直角の長さ)。線と線の間隔でもある
	HarvesterLength = 18, -- 機械の長さ(進行方向)。田んぼの外から入る距離でもある
	HarvesterHeight = 10, -- 機械の高さ(見た目のみ)
	HarvesterEntryDelaySeconds = 3, -- 出穂の段階になってから、動き始めるまでの時間(秒)
	HarvesterLaneMargin = 7, -- 田んぼのはしから、1本目の線(と東の最後の線)までの距離
	-- 経路の長さ ≒ 線の数 ×(FieldSize + HarvesterLength×2)+ 線の間のずれ。いまは線9本で約1500
	HarvesterActiveStage = 3, -- 稲刈り機の出番になる稲の段階(3 = 出穂)
	HarvesterMaxStepSeconds = 0.25, -- 1フレームで進める時間の上限(秒)。重いときに瞬間移動しないため

	-- 稲刈り機の見た目(図形だけ。外部素材は使わない)
	HarvesterColor = Color3.fromRGB(140, 180, 60), -- 胴体の色(黄緑がかった機械の色)
	HarvesterBladeColor = Color3.fromRGB(190, 195, 200), -- 刈り取りの刃の色(銀)
	HarvesterCabinColor = Color3.fromRGB(90, 130, 150), -- 運転席の色
	HarvesterWheelColor = Color3.fromRGB(40, 40, 40), -- 車輪の色
	HarvesterBladeLength = 3, -- 刃の前後の長さ
	HarvesterBladeHeight = 3, -- 刃の高さ
	HarvesterBodyHeight = 4, -- 胴体の高さ
	HarvesterWheelDiameter = 4, -- 車輪の直径
	HarvesterWheelThickness = 2.5, -- 車輪の厚さ
	HarvesterCabinLength = 6, -- 運転席の前後の長さ
	HarvesterCabinWidthRatio = 0.6, -- 運転席の幅(胴体の幅に対する割合)

	-- 粒子の演出(仕様書 009)。粒子の画像は Roblox の既定のまま。重いときは Rate(1秒に出す数)を下げる。調整のしかたは docs/design/particles.md
	-- 稲刈り機の刈りくず(刃から、前と上に飛ぶ。動いている間だけ)
	HarvesterChaffRate = 30, -- 1秒に出す数
	HarvesterChaffLifetimeMin = 0.6, -- 寿命の最小(秒)
	HarvesterChaffLifetimeMax = 1.0, -- 寿命の最大(秒)
	HarvesterChaffSpeedMin = 10, -- 飛び出す速さの最小
	HarvesterChaffSpeedMax = 18, -- 飛び出す速さの最大
	HarvesterChaffSizeStart = 0.5, -- 出たときの大きさ(だんだん小さくなる)
	HarvesterChaffSizeEnd = 0.3, -- 消える直前の大きさ(仕様書 009 の 0.3〜0.5 の範囲)
	HarvesterChaffColorStart = Color3.fromRGB(110, 190, 70), -- 出たときの色(緑)
	HarvesterChaffColorEnd = Color3.fromRGB(235, 190, 50), -- 消える直前の色(黄金)
	HarvesterChaffAcceleration = Vector3.new(0, -12, 0), -- 加速(世界の向き。下向きにすると重力で落ちる。強いと、すぐ床の下へ落ちるので弱めにする)
	HarvesterChaffUpwardRatio = 0.8, -- 飛ぶ向きの上向きの強さ(前向きを 1 としたときの割合。0 で真っ直ぐ前、大きいほど上へ飛ぶ)
	HarvesterChaffSpreadAngle = Vector2.new(35, 35), -- 広がる角度(度)
	HarvesterChaffTransparencyStart = 0, -- 出たときの透明度
	HarvesterChaffLightEmission = 0, -- 光り具合(0 = 光らない)

	-- 稲刈り機の土ぼこり(後ろの車輪のあたりから、ふんわり。動いている間だけ)
	HarvesterDustRate = 8, -- 1秒に出す数(少なめ)
	HarvesterDustLifetimeMin = 1.0, -- 寿命の最小(秒)
	HarvesterDustLifetimeMax = 1.6, -- 寿命の最大(秒)
	HarvesterDustSpeedMin = 2, -- 飛び出す速さの最小
	HarvesterDustSpeedMax = 5, -- 飛び出す速さの最大
	HarvesterDustSizeStart = 3, -- 出たときの大きさ(だんだん大きくなる)
	HarvesterDustSizeEnd = 7, -- 消える直前の大きさ
	HarvesterDustColor = Color3.fromRGB(190, 160, 120), -- 色(薄い茶色)
	HarvesterDustTransparencyStart = 0.6, -- 出たときの透明度(消える直前は 1)
	HarvesterDustAcceleration = Vector3.new(0, 1.5, 0), -- 加速(少し上へふんわり)
	HarvesterDustSpreadAngle = Vector2.new(50, 50), -- 広がる角度(度)
	HarvesterDustDrag = 1, -- 空気の抵抗(大きいほど早く止まる)
	HarvesterDustLightEmission = 0, -- 光り具合
	HarvesterDustSourceHeight = 0.5, -- 土ぼこりの発生源(見えない箱)の高さ
	HarvesterDustSourceLength = 2, -- 土ぼこりの発生源の前後の長さ

	-- 粒子の回転(刈りくず・土ぼこり共通の見た目の調整)
	HarvesterParticleRotationMaxDeg = 360, -- 粒子の最初の向き(0〜この値の度)
	HarvesterChaffRotSpeedDeg = 180, -- 刈りくずの回る速さ(度/秒。±この値)
	HarvesterDustRotSpeedDeg = 30, -- 土ぼこりの回る速さ(度/秒。±この値)

	-- ザリガニの水しぶき(潜る・浮上するとき。SplashBurstSeconds の間だけ出す)
	SplashBurstSeconds = 0.25, -- 出し続ける時間(秒)
	SplashRate = 80, -- 1秒に出す数(0.25秒で約20個)
	SplashLifetimeMin = 0.4, -- 寿命の最小(秒)
	SplashLifetimeMax = 0.7, -- 寿命の最大(秒)
	SplashSpeedMin = 8, -- 飛び出す速さの最小
	SplashSpeedMax = 14, -- 飛び出す速さの最大
	SplashSizeStart = 0.6, -- 出たときの大きさ(だんだん小さくなる)
	SplashSizeEnd = 0.1, -- 消える直前の大きさ
	SplashColor = Color3.fromRGB(190, 225, 255), -- 色(青白い)
	SplashTransparencyStart = 0.1, -- 出たときの透明度
	SplashAcceleration = Vector3.new(0, -40, 0), -- 加速(下向きで、しぶきが落ちる)
	SplashSpreadAngle = Vector2.new(70, 70), -- 広がる角度(度)
	SplashLightEmission = 0.3, -- 光り具合(少し明るく)

	-- 農家さんの見た目(外部素材は使わず、色と図形だけ)
	FarmerSkinColor = Color3.fromRGB(224, 172, 105), -- 肌
	FarmerClothesColor = Color3.fromRGB(60, 90, 150), -- 作業着(藍色)
	FarmerHatColor = Color3.fromRGB(230, 205, 120), -- 麦わら帽子
	FarmerHatBrimDiameter = 3.6, -- 帽子のつばの直径
	FarmerHatBrimThickness = 0.2, -- 帽子のつばの厚さ
	FarmerHatCrownDiameter = 2.2, -- 帽子の山の部分の直径
	FarmerHatCrownHeight = 0.8, -- 帽子の山の部分の高さ

	-- 農家さんの作成のやり直しと、代わりの簡易モデル(Part だけで作る人型)
	FarmerCreateMaxAttempts = 3, -- 人型の作成を試す最大回数
	FarmerCreateRetryWaitSeconds = 2, -- 失敗してから、やり直すまでの待ち時間(秒)
	FarmerFallbackRootSize = Vector3.new(2, 2, 1), -- 簡易モデル:HumanoidRootPart の大きさ(見えない)
	FarmerFallbackTorsoSize = Vector3.new(2, 3, 1), -- 簡易モデル:胴の大きさ
	FarmerFallbackHeadSize = Vector3.new(1.6, 1.6, 1.6), -- 簡易モデル:頭の大きさ

	-- 稲の株と成長(仕様書 007)。数字は仮の初期値
	RiceJitter = 1.2, -- 株の位置の、ランダムなずれの最大(スタッド)
	RiceBladeCount = 3, -- 1株の葉の数
	RiceEarCount = 2, -- 1株の穂の数(葉の数以下)
	RiceHeightMin = 2, -- 稲の高さの最小(育ち始め)
	RiceHeightMax = 9, -- 稲の高さの最大(育ちきり)
	RiceHeightVariation = 0.15, -- 株ごとの高さのばらつき(0.15 = ±15%)
	RiceStubbleHeight = 0.5, -- 刈り株の高さ
	RiceGrowthUpdateSeconds = 10, -- 育つ見た目の更新間隔(秒)
	RiceRandomSeed = 20261103, -- 株の配置の乱数の種(同じ値なら、毎回同じ配置)
	RiceBladeWidth = 0.5, -- 葉の幅
	RiceBladeThickness = 0.08, -- 葉の厚さ
	RiceBladeTiltMinDeg = 6, -- 葉の傾きの最小(度。0 = まっすぐ上)
	RiceBladeTiltMaxDeg = 26, -- 葉の傾きの最大(度)
	RiceEarLength = 1.8, -- 穂の長さ(育ちきったとき)
	RiceEarThickness = 0.2, -- 穂の太さ
	-- 穂の垂れ具合は「真上から何度、葉の倒れる向きへ傾けるか」。0 = 真上、90 = 真横、130 = 下向き気味、180 = 真下
	-- 注意:0 や 180 にすると、穂の向きの計算(外積)が 0 になって壊れる。1〜179 の間にする
	RiceEarDroopStartDeg = 10, -- 穂の垂れ具合(出始め)。0 にすると、穂の向きの計算が壊れるので、0 にしない
	RiceEarDroopEndDeg = 130, -- 穂の垂れ具合(育ちきったとき。真上から130度 = 下向き気味)
	RiceBladeYawJitter = 0.4, -- 葉の向き(横回り)のランダムなずれの最大(ラジアン。±この値)
	RiceBladeLengthFactorMin = 0.75, -- 葉ごとの長さの割合の最小
	RiceBladeLengthFactorMax = 1.0, -- 葉ごとの長さの割合の最大
	RiceColorMidProgress = 0.5, -- 稲の色が「黄緑」になる育ち具合(0〜1)。ここまでが 緑 → 黄緑、ここから 黄緑 → 黄金

	-- 風で稲がゆれる(仕様書 008。クライアントだけで動かす。調整のしかたは docs/design/rice-sway.md)
	RiceSwayRadius = 40, -- ゆらす範囲(自分のキャラクターからの距離。重いときは小さく)
	RiceSwayHz = 20, -- 1秒の更新回数(重いときは下げる)。0 にしない(0 で割るため)
	RiceSwayMaxDeg = 6, -- 傾きの最大(度)
	RiceSwayPeriodSeconds = 3.2, -- 1回のゆれの周期(秒)。0 にしない(0 で割るため)
	RiceWindDirectionDeg = 20, -- 風の基本の向き(度。0 = 南(+Z)の向きへ吹く、90 = 東(+X)の向きへ吹く)
	RiceWindWaveLength = 30, -- 波の長さ(この距離ごとに、ゆれの位相が1周する)。0 にしない(0 で割るため)
	RiceWindGustPeriodSeconds = 11, -- 強風の強弱の周期(秒)。0 にしない(0 で割るため)
	RiceWindGustMin = 0.4, -- 風がいちばん弱いときの強さの割合(0〜1)
	RiceWindGustMax = 1.0, -- 風がいちばん強いときの強さの割合(0〜1)
	RiceWindDirWobbleDeg = 5, -- 風の向きのふらつきの大きさ(度。±この値)
	RiceWindDirWobblePeriodSeconds = 23, -- 風の向きのふらつきの周期(秒)。0 にしない(0 で割るため)
	RiceSwayRebaseDistance = 0.02, -- 部品の位置がこれより動いていたら、サーバーが変えたとみなす(スタッド)
	RiceSwayRebaseDot = 0.9999, -- 部品の向きの内積がこれより小さければ、サーバーが変えたとみなす(1 = 同じ向き)

	-- 田んぼの色と水
	FieldColor = Color3.fromRGB(94, 70, 48), -- 泥の茶色
	WallColor = Color3.fromRGB(105, 115, 65), -- あぜ道の緑がかった茶色
	RiceGreenColor = Color3.fromRGB(90, 170, 70), -- 稲の色:育ち始め(緑)
	RiceYellowGreenColor = Color3.fromRGB(160, 190, 60), -- 稲の色:途中(黄緑)
	RiceGoldColor = Color3.fromRGB(230, 190, 50), -- 稲の色:育ちきり(黄金)
	RiceStubbleColor = Color3.fromRGB(225, 205, 130), -- 刈り株の色(薄い黄色)
	RiceEarColor = Color3.fromRGB(235, 200, 90), -- 穂の色
	WaterColor = Color3.fromRGB(70, 120, 110), -- 水の色(茶色がかった青緑)
	WaterTransparency = 0.6, -- 水面の透明度
	WaterReflectance = 0.1, -- 水面の反射
	WaterDepth = 0.2, -- 水の層の厚さ(ゆか上面からの高さ)
	SpawnColor = Color3.fromRGB(160, 140, 100), -- スタート地点

	-- 光と空気(仕様書 007 の 4・5。クライアントだけで変える。調整のしかたは docs/design/lighting.md)
	ClockTimeStart = 7, -- ラウンドの始まりの時刻(朝7時)
	ClockTimeEnd = 17.5, -- 稲刈りの日の時刻(夕方17時30分)
	LightSmoothRate = 2, -- 光がなめらかに近づく速さ(大きいほど速い。1秒ごとの階段をならす)
	LightResetRate = 8, -- 新しいラウンドで、朝へ戻る速さ(大きいほど速い。8で約0.5秒)
	LightResetDropThreshold = 0.05, -- 進み具合がこれ以上下がったら「新しいラウンド」とみなす(速く戻す)
	LightUpdateEpsilon = 0.0005, -- 進み具合の変化がこれより小さい間は、見た目を更新しない(軽くするため。0.0005 = 0.05%)
	LightEffectWaitSeconds = 10, -- RoundState を待つ最大の時間(秒)
	-- Lighting 本体(Brightness は明るさ。Ambient は影の部分の色、OutdoorAmbient は屋外の環境光)
	LightBrightnessMorning = 2,
	LightBrightnessEvening = 2.5,
	LightAmbientMorning = Color3.fromRGB(90, 95, 105),
	LightAmbientEvening = Color3.fromRGB(110, 80, 70),
	LightOutdoorAmbientMorning = Color3.fromRGB(120, 125, 135),
	LightOutdoorAmbientEvening = Color3.fromRGB(150, 105, 85),
	-- Atmosphere(もや)。密度と Haze は、朝 → 昼(進み具合0.5)→ 夕方の3点で補間する
	LightAtmoDensityMorning = 0.35, -- 朝は、うっすら霧(少し濃いめ)
	LightAtmoDensityNoon = 0.2, -- 昼は晴れる
	LightAtmoDensityEvening = 0.3, -- 夕方は、金色のもや
	LightAtmoHazeMorning = 1.2,
	LightAtmoHazeNoon = 0.4,
	LightAtmoHazeEvening = 1.6,
	LightAtmoOffsetMorning = 0.1,
	LightAtmoOffsetEvening = 0.25,
	LightAtmoColorMorning = Color3.fromRGB(200, 208, 218), -- 朝の霧(白っぽい青)
	LightAtmoColorEvening = Color3.fromRGB(255, 195, 125), -- 夕方のもや(金色)
	LightAtmoDecayMorning = Color3.fromRGB(150, 165, 185),
	LightAtmoDecayEvening = Color3.fromRGB(255, 150, 80),
	LightAtmoGlareMorning = 0,
	LightAtmoGlareEvening = 0.6,
	-- ColorCorrection(色の補正)
	LightColorBrightnessMorning = 0,
	LightColorBrightnessEvening = 0.02,
	LightColorContrastMorning = 0,
	LightColorContrastEvening = 0.1,
	LightColorSaturationMorning = 0,
	LightColorSaturationEvening = 0.15,
	LightColorTintMorning = Color3.fromRGB(255, 255, 255), -- 朝は白(色をつけない)
	LightColorTintEvening = Color3.fromRGB(255, 225, 190), -- 夕方は暖かい色
	-- Bloom(光のにじみ)
	LightBloomIntensityMorning = 0.2,
	LightBloomIntensityEvening = 0.6,
	LightBloomSizeMorning = 18,
	LightBloomSizeEvening = 32,
	LightBloomThresholdMorning = 1.8, -- 小さいほど、にじみやすい
	LightBloomThresholdEvening = 1.2,
	-- SunRays(光の筋)。強くなりすぎないようにする
	LightSunRaysIntensityMorning = 0.03,
	LightSunRaysIntensityEvening = 0.1,
	LightSunRaysSpread = 0.6,
}

return Config
