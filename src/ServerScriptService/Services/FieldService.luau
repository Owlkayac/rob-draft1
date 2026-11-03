--!strict
-- 田んぼの舞台(ゆか・あぜ・稲・スタート地点)をコードで作る部品。仕様書 004 の 1。
-- 外部の素材は使わず、図形と色だけで作る。

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)

local FieldService = {}

-- 作った稲(1本ずつの Part)の一覧。段階を変えるときに使う
local ricePlants: { BasePart } = {}
-- いまの稲の段階(0 = まだ作っていない)
local currentStage = 0

-- 図形(Part)を1つ作る共通の関数。すべて固定(Anchored)にする
local function makePart(name: string, size: Vector3, position: Vector3, color: Color3, parent: Instance): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Position = position
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.Anchored = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

-- ゆか:泥の色の大きな平らな板
local function buildFloor(field: Folder)
	local size = Vector3.new(Config.FieldSize, Config.FieldFloorThickness, Config.FieldSize)
	local centerY = Config.FieldFloorTopY - Config.FieldFloorThickness / 2
	makePart("Floor", size, Vector3.new(0, centerY, 0), Config.FieldColor, field)
end

-- あぜ:ゆかの四辺に壁を立てる(ゆかの外側に置くので、中の広さは FieldSize のまま)
local function buildWalls(field: Folder)
	local half = Config.FieldSize / 2
	local thick = Config.FieldWallThickness
	local height = Config.FieldWallHeight
	local length = Config.FieldSize + thick * 2 -- 角にすきまができないよう、両端を延ばす
	local centerY = Config.FieldFloorTopY + height / 2
	local offset = half + thick / 2

	local alongX = Vector3.new(length, height, thick) -- 北と南の壁
	local alongZ = Vector3.new(thick, height, length) -- 東と西の壁
	makePart("WallNorth", alongX, Vector3.new(0, centerY, -offset), Config.WallColor, field)
	makePart("WallSouth", alongX, Vector3.new(0, centerY, offset), Config.WallColor, field)
	makePart("WallEast", alongZ, Vector3.new(offset, centerY, 0), Config.WallColor, field)
	makePart("WallWest", alongZ, Vector3.new(-offset, centerY, 0), Config.WallColor, field)
end

-- 稲:格子状に細い箱を並べる(歩く邪魔にならず、経路探索にも影響しない)
local function buildRice(field: Folder)
	local riceFolder = Instance.new("Folder")
	riceFolder.Name = "Rice"
	riceFolder.Parent = field

	local count = math.floor(Config.FieldSize / Config.RiceSpacing) -- 1列の本数
	local startOffset = (count + 1) / 2
	local width = Config.RiceWidth
	for ix = 1, count do
		for iz = 1, count do
			local x = (ix - startOffset) * Config.RiceSpacing
			local z = (iz - startOffset) * Config.RiceSpacing
			-- 高さと位置は、SetGrowthStage で決める。ここでは仮の値
			local plant = makePart("Rice", Vector3.new(width, 1, width), Vector3.new(x, Config.FieldFloorTopY, z), Config.RiceGreenColor, riceFolder)
			plant.CanCollide = false
			plant.CanQuery = false
			plant.CanTouch = false
			table.insert(ricePlants, plant)
		end
	end
end

-- スタート地点:田んぼの南の端(南は +Z の向き)
local function buildSpawn(field: Folder)
	local spawnPoint = Instance.new("SpawnLocation")
	spawnPoint.Name = "SpawnLocation"
	spawnPoint.Anchored = true
	spawnPoint.Neutral = true -- チームなし
	spawnPoint.Duration = 0 -- 生まれたときの無敵(ForceField)をつけない
	spawnPoint.AllowTeamChangeOnTouch = false
	spawnPoint.Size = Vector3.new(Config.SpawnSize, 1, Config.SpawnSize)
	spawnPoint.Color = Config.SpawnColor
	local z = Config.FieldSize / 2 - Config.SpawnEdgeOffset
	spawnPoint.Position = Vector3.new(0, Config.FieldFloorTopY + 0.5, z)
	spawnPoint.Parent = field
end

-- Studio の Baseplate テンプレートが最初から置く SpawnLocation(Workspace 直下)を無効にする。
-- これで、必ず田んぼのスタート地点(Field の中)で生まれる
local function disableDefaultSpawns()
	for _, child in Workspace:GetChildren() do
		if child:IsA("SpawnLocation") then
			child.Enabled = false
		end
	end
end

-- 稲の段階(1〜3)を変える。高さと色を変える。底は、いつもゆかにつけておく。
-- 段階が変わったときだけ作業する(毎フレームは呼ばない)
local function setGrowthStage(stage: number)
	local lastStage = #Config.RiceHeights
	local clamped = math.clamp(math.floor(stage), 1, lastStage)
	if clamped == currentStage then
		return
	end
	currentStage = clamped

	local height = Config.RiceHeights[clamped]
	local color = if clamped >= lastStage then Config.RiceGoldColor else Config.RiceGreenColor
	local width = Config.RiceWidth
	for _, plant in ricePlants do
		local position = plant.Position
		plant.Size = Vector3.new(width, height, width)
		plant.Position = Vector3.new(position.X, Config.FieldFloorTopY + height / 2, position.Z)
		plant.Color = color
	end
end

-- 外から使えるように公開する
FieldService.SetGrowthStage = setGrowthStage

-- 田んぼ全体を作る(ゲーム開始時に1回だけ呼ぶ)
function FieldService.Build()
	local old = Workspace:FindFirstChild("Field")
	if old then
		old:Destroy()
	end
	table.clear(ricePlants)
	currentStage = 0

	local field = Instance.new("Folder")
	field.Name = "Field"
	buildFloor(field)
	buildWalls(field)
	buildRice(field)
	buildSpawn(field)
	field.Parent = Workspace
	disableDefaultSpawns()

	setGrowthStage(1)
end

-- 天敵の見回り用の地点(田んぼの中の5か所)。ゆかの上の、歩ける高さの座標
function FieldService.GetPatrolPoints(): { Vector3 }
	local offset = Config.FieldSize * Config.PatrolPointRatio
	local y = Config.FieldFloorTopY + Config.PatrolPointHeight
	return {
		Vector3.new(0, y, 0), -- 中央
		Vector3.new(-offset, y, -offset), -- 北西
		Vector3.new(offset, y, -offset), -- 北東
		Vector3.new(offset, y, offset), -- 南東
		Vector3.new(-offset, y, offset), -- 南西
	}
end

-- 田んぼの場所と大きさ。Center はゆかの上面の中心、Size は (幅, 壁の高さ, 奥行き)
function FieldService.GetFieldBounds(): { Center: Vector3, Size: Vector3 }
	return {
		Center = Vector3.new(0, Config.FieldFloorTopY, 0),
		Size = Vector3.new(Config.FieldSize, Config.FieldWallHeight, Config.FieldSize),
	}
end

return FieldService
