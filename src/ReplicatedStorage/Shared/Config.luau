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
	CrayfishColor = Color3.fromRGB(200, 40, 30), -- ザリガニの仮の色(赤)

	-- 田んぼの舞台(仕様書 004)。数字は仮の初期値。
	FieldSize = 120, -- 田んぼの一辺の長さ
	FieldWallHeight = 8, -- あぜ(壁)の高さ
	FieldWallThickness = 2, -- あぜの厚さ
	FieldFloorThickness = 1, -- ゆかの厚さ
	FieldFloorTopY = 0.5, -- ゆかの上面の高さ(Baseplate の上面は y=0)
	RiceSpacing = 8, -- 稲と稲の間隔
	RiceWidth = 1, -- 稲1本の太さ
	RiceHeights = { 2, 5, 9 }, -- 段階ごとの稲の高さ
	SpawnSize = 6, -- スタート地点の一辺の長さ
	SpawnEdgeOffset = 3, -- スタート地点を、南の端からどれだけ内側に置くか
	PatrolPointHeight = 3, -- 見回り地点の、ゆかの上面からの高さ(歩ける高さ)
	PatrolPointRatio = 0.25, -- 見回り地点の位置(田んぼの一辺に対する割合。中心から±この割合)

	-- 稲の成長とクリア(仕様書 003)
	RoundSeconds = 300, -- 1回の長さ(稲刈りの日までの時間・秒)
	GrowthStageSeconds = { 75, 225 }, -- 段階2・3に切り替わる経過時間(秒)
	SightMultipliers = { 1.0, 0.8, 0.6 }, -- 段階ごとの、天敵の発見距離の倍率
	StageNames = { "田植え", "成長", "出穂", "稲刈りの日" }, -- 段階の名前
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

	-- 田んぼの色
	FieldColor = Color3.fromRGB(94, 70, 48), -- 泥の茶色
	WallColor = Color3.fromRGB(105, 115, 65), -- あぜ道の緑がかった茶色
	RiceGreenColor = Color3.fromRGB(90, 170, 70), -- 稲(段階1・2)
	RiceGoldColor = Color3.fromRGB(230, 190, 50), -- 稲(段階3・出穂)
	SpawnColor = Color3.fromRGB(160, 140, 100), -- スタート地点
}

return Config
