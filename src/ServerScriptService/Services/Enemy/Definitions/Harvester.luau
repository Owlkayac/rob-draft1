--!strict
-- 天敵の種類「稲刈り機」の定義。(仕様書 006)
-- Humanoid も経路探索も使わない。位置は Sweep(行動)が毎フレーム動かす。
-- 農家さんと違う点は、定義が持つ「任意の関数」で表す:
--   IsActive(いま出番か)、CheckCatch(捕まえ方)、FindBody / IsModelUsable(Humanoid なしの体の扱い)。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Types = require(script.Parent.Parent.Types)
local Sweep = require(script.Parent.Parent.Behaviors.Sweep)
local SweepRoute = require(script.Parent.Parent.SweepRoute)
local RoundService = require(script.Parent.Parent.Parent.RoundService)

-- 見た目の部品は ServerStorage/Modules にある(Rojo の対応は default.project.json)
local modulesFolder = ServerStorage:WaitForChild("Modules", 10)
assert(modulesFolder, "[Harvester] ServerStorage/Modules が見つかりません")
local harvesterModelScript = modulesFolder:WaitForChild("HarvesterModel", 10)
assert(harvesterModelScript, "[Harvester] HarvesterModel が見つかりません")
local HarvesterModel = require(harvesterModelScript :: ModuleScript)

-- 出番か:遊んでいるプレイヤーのうち、稲の段階が「出穂」(Config.HarvesterActiveStage)の人が1人でもいれば true
local function isActive(): boolean
	for _, player in Players:GetPlayers() do
		if RoundService.IsPlaying(player) and RoundService.GetStage(player) == Config.HarvesterActiveStage then
			return true
		end
	end
	return false
end

-- 捕まえる判定:稲刈り機の向きと位置を考えた長方形(横幅 HarvesterWidth、長さ HarvesterLength)の中なら true。
-- 高さは見ない。潜っているかどうかも見ない(機械は、見つけるのではなく、ただ通るため)。
-- ctx.Model:GetPivot() は「機械の真ん中の底」。その座標系にすると、横が X、前後が Z になる
local function checkCatch(ctx: Types.Context, _player: Player, root: BasePart): boolean
	local localPosition = ctx.Model:GetPivot():PointToObjectSpace(root.Position)
	return math.abs(localPosition.X) <= Config.HarvesterWidth / 2 and math.abs(localPosition.Z) <= Config.HarvesterLength / 2
end

-- 体の部品:Humanoid はなし。位置の基準は PrimaryPart(胴体)
local function findBody(model: Model): (Humanoid?, BasePart?)
	return nil, model.PrimaryPart
end

-- モデルがまだ使えるか:Workspace にあり、基準の部品が残っている
local function isModelUsable(ctx: Types.Context): boolean
	return ctx.Model.Parent ~= nil and ctx.Root.Parent ~= nil
end

-- 足元の高さ(ワールドのY):モデルを囲む箱の底
local function getFootY(model: Model): number
	local boxCFrame, boxSize = model:GetBoundingBox()
	return boxCFrame.Position.Y - boxSize.Y / 2
end

-- 置く:見回り地点の代わりに、いつも入り口(北のはしの外)に置く。point は使わない
local function placeAt(model: Model, _point: Vector3)
	model:PivotTo(CFrame.lookAt(SweepRoute.GetStartPoint(), SweepRoute.GetStartPoint() + SweepRoute.GetStartDirection()))
end

local function onPlaced(_model: Model)
	-- 位置はコードで動かす(Anchored)ので、やることはない
end

local Harvester: Types.Definition = {
	Name = "Harvester",
	Create = HarvesterModel.Create,
	GetFootY = getFootY,
	PlaceAt = placeAt,
	OnPlaced = onPlaced,
	BaseStats = {
		Speed = Config.HarvesterSpeed,
	},
	Behaviors = {
		Sweep = Sweep,
	},
	InitialBehavior = "Sweep",
	IsActive = isActive,
	CheckCatch = checkCatch,
	ResetOnCatch = false, -- 捕まえても、機械は止まらず、そのまま進む
	FindBody = findBody,
	IsModelUsable = isModelUsable,
	SkipScan = true, -- 見回しはしない(見つける・見つけないではなく、ただ通る)
}

return Harvester
