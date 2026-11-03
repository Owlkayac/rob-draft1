--!strict
-- 天敵の種類「農家さん」の定義。(仕様書 002)
-- 名前、見た目の作り方、基本の数字、使う行動の一覧、最初の行動を書く。
-- 新しい種類(サギなど)は、このファイルをまねて Definitions に足し、EnemyService の一覧に登録する。

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Types = require(script.Parent.Parent.Types)
local Patrol = require(script.Parent.Parent.Behaviors.Patrol)
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
	LoseSightSeconds = Config.FarmerLoseSightSeconds,
	SearchSeconds = Config.FarmerSearchSeconds,
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
		Chase = Chase,
		Search = Search,
	},
	InitialBehavior = "Patrol",
}

return Farmer
