--!strict
-- 天敵の種類「農家さん」の定義。(仕様書 002)
-- 名前、見た目の作り方、基本の数字、使う行動の一覧、最初の行動を書く。
-- 新しい種類(サギなど)は、このファイルをまねて Definitions に足し、EnemyService の一覧に登録する。

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Types = require(script.Parent.Parent.Types)
local Patrol = require(script.Parent.Parent.Behaviors.Patrol)
local Notice = require(script.Parent.Parent.Behaviors.Notice)
local Chase = require(script.Parent.Parent.Behaviors.Chase)
local Search = require(script.Parent.Parent.Behaviors.Search)

-- 見た目の部品は ServerStorage/Modules にある(Rojo の対応は default.project.json)
local modulesFolder = ServerStorage:WaitForChild("Modules", 10)
assert(modulesFolder, "[Farmer] ServerStorage/Modules が見つかりません")
local farmerModelScript = modulesFolder:WaitForChild("FarmerModel", 10)
assert(farmerModelScript, "[Farmer] FarmerModel が見つかりません")
local FarmerModel = require(farmerModelScript :: ModuleScript)

-- 大きさ(仕様書 002 の 8):
--   距離の数字は × 実際の倍率、歩く速さは × FarmerSpeedMultiplier だけ、発見距離は倍率をかけない
local speed = Config.FarmerSpeedMultiplier

-- 距離の数字(標準サイズ基準)を、倍率 scale で実際の値にして BaseStats に入れる
local function applyScale(stats: Types.StatTable, scale: number)
	stats.CatchDistance = Config.FarmerCatchDistance * scale
	stats.CatchHiddenDistance = Config.FarmerCatchHiddenDistance * scale
	stats.PatrolArriveDistance = Config.PatrolArriveDistance * scale
	stats.WaypointReachDistance = Config.WaypointReachDistance * scale
	stats.AgentRadius = Config.PathAgentRadius * scale
	stats.AgentHeight = Config.PathAgentHeight * scale
end

local baseStats: Types.StatTable = {
	WalkSpeed = Config.FarmerWalkSpeed * speed,
	ChaseSpeed = Config.FarmerChaseSpeed * speed,
	SightDistance = Config.FarmerSightDistance, -- 倍率をかけない
	-- 見失う・探す時間(最小〜最大のあいだでランダム。仕様書 014)
	LoseSightSecondsMin = Config.FarmerLoseSightSecondsMin,
	LoseSightSecondsMax = Config.FarmerLoseSightSecondsMax,
	SearchSecondsMin = Config.FarmerSearchSecondsMin,
	SearchSecondsMax = Config.FarmerSearchSecondsMax,
	SearchRoamRadius = Config.FarmerSearchRoamRadius,
	SearchRoamSpotsMin = Config.FarmerSearchRoamSpotsMin,
	SearchRoamSpotsMax = Config.FarmerSearchRoamSpotsMax,
	-- 見回りのランダム性
	RoamPointChance = Config.FarmerRoamPointChance,
	RoamWallMargin = Config.FarmerRoamWallMargin,
	PauseChance = Config.FarmerPauseChance,
	PauseSecondsMin = Config.FarmerPauseSecondsMin,
	PauseSecondsMax = Config.FarmerPauseSecondsMax,
	WalkSpeedJitter = Config.FarmerWalkSpeedJitter,
	PatrolTargetTimeoutSeconds = Config.FarmerPatrolTargetTimeoutSeconds,
	LookAroundMaxRad = math.rad(Config.FarmerLookAroundMaxDeg),
	PauseTurnRadPerSecond = math.rad(Config.FarmerPauseTurnDegPerSecond),
	HunchIntervalMin = Config.FarmerHunchIntervalMin,
	HunchIntervalMax = Config.FarmerHunchIntervalMax,
	HunchChance = Config.FarmerHunchChance,
	HunchErrorRadius = Config.FarmerHunchErrorRadius,
	-- 気づく・追跡のランダム性
	NoticeSecondsMin = Config.FarmerNoticeSecondsMin,
	NoticeSecondsMax = Config.FarmerNoticeSecondsMax,
	NoticeTurnRadPerSecond = math.rad(Config.FarmerNoticeTurnDegPerSecond),
	BurstIntervalMin = Config.FarmerBurstIntervalMin,
	BurstIntervalMax = Config.FarmerBurstIntervalMax,
	BurstSeconds = Config.FarmerBurstSeconds,
	BurstMultiplier = Config.FarmerBurstMultiplier,
	StumbleIntervalMin = Config.FarmerStumbleIntervalMin,
	StumbleIntervalMax = Config.FarmerStumbleIntervalMax,
	StumbleSeconds = Config.FarmerStumbleSeconds,
	-- 追跡の速さの上限:ザリガニの歩く速さ × 比(公平さ。ダッシュしても超えない)
	ChaseSpeedMax = Config.CrayfishWalkSpeed * Config.FarmerChaseMaxSpeedRatio,
	-- 出現直後に、プレイヤーを見つけない時間
	StartGraceSeconds = Config.FarmerStartGraceSeconds,
}
applyScale(baseStats, Config.FarmerScale) -- 最初は設定の倍率。モデルを作るたびに、実際の倍率で入れ直す

-- 見た目を作る。大きくするのに失敗して 1 倍のままのときは、距離の数字も 1 倍に合わせる
local function create(): Model
	local model, usedScale = FarmerModel.Create()
	applyScale(baseStats, usedScale)
	return model
end

local Farmer: Types.Definition = {
	Name = "Farmer",
	Create = create,
	GetFootY = FarmerModel.GetFootY,
	PlaceAt = FarmerModel.PlaceAt,
	OnPlaced = FarmerModel.ClaimServerOwnership,
	BaseStats = baseStats,
	Behaviors = {
		Patrol = Patrol,
		Notice = Notice, -- 見つけたあと、すぐには走らず、立ち止まって相手のほうを向く(仕様書 014)
		Chase = Chase,
		Search = Search,
	},
	InitialBehavior = "Patrol",
	OnBehaviorChanged = FarmerModel.SetState, -- 行動が変わるたびに、EnemyState と頭の上の「!」「?」を切り替える
}

return Farmer
