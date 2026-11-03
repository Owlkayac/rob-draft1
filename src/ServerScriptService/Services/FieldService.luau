--!strict
-- 田んぼの舞台(ゆか・水・あぜ・稲・スタート地点)をコードで作る部品。仕様書 004 の 1 と、仕様書 007 の 1〜3。
-- 外部の素材は使わず、図形・色・Roblox に最初からある素材(Material)だけで作る。
-- 稲は「株」で作る。1株 = 葉3枚(細長い板)+ 穂2本(細い円柱)。

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)

-- 葉(細長い板)1枚の記録。向きと傾きは、株を作るときにランダムで決めて、変えない
type Blade = {
	Part: Part,
	Rotation: CFrame, -- 向き(Yaw)と傾き(Tilt)をあわせた回転。UpVector が葉の伸びる向き
	Heading: Vector3, -- 葉が倒れていく、水平の向き(長さ1)
	CosTilt: number, -- 傾きの cos(高さから長さを出すのに使う)
	LengthFactor: number, -- 葉ごとの長さの割合(0.75〜1.0)
}

-- 穂(細い円柱)1本の記録。BladeIndex の葉の先から生える
type Ear = {
	Part: Part,
	BladeIndex: number,
}

-- 稲1株の記録
type Plant = {
	X: number, -- 株の中心の位置(ずれを含む)
	Z: number,
	HeightFactor: number, -- 株ごとの高さの割合(1 前後)
	Blades: { Blade },
	Ears: { Ear },
	Cut: boolean, -- 刈られたか(刈られたら、もう育たない)
}

-- 素材(Material)は、ここにまとめる(色は Config)
local MATERIAL_FLOOR = Enum.Material.Mud -- ゆか:泥
local MATERIAL_WATER = Enum.Material.Glass -- 水面:ガラス
local MATERIAL_WALL = Enum.Material.Grass -- あぜ:草
local MATERIAL_BLADE = Enum.Material.Grass -- 葉:草
local MATERIAL_EAR = Enum.Material.Sand -- 穂:砂

local FieldService = {}

-- 全部の株の一覧(育ちの更新や、やり直しで順番に回す)
local allPlants: { Plant } = {}
-- 格子の番号 [ix][iz] で株を探す表(CutRice が近くの株だけを調べるため)
local plantGrid: { [number]: { [number]: Plant } } = {}
-- 格子の情報(buildRice で決める)
local gridCount = 0 -- 1列の株の数
local gridOffset = 0 -- 番号から位置を出すための値((count + 1) / 2)
-- いまの育ち具合(0〜1)。-1 = まだ見た目を作っていない
local lastProgress = -1
-- 刈られた株が1つでもあるか(ResetRice を軽くするため)
local anyCut = false

-- 図形(Part)を1つ作る共通の関数。すべて固定(Anchored)にする
local function makePart(
	name: string,
	size: Vector3,
	position: Vector3,
	color: Color3,
	material: Enum.Material,
	parent: Instance
): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Position = position
	part.Color = color
	part.Material = material
	part.Anchored = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

-- ゆか:泥の素材の大きな平らな板
local function buildFloor(field: Folder)
	local size = Vector3.new(Config.FieldSize, Config.FieldFloorThickness, Config.FieldSize)
	local centerY = Config.FieldFloorTopY - Config.FieldFloorThickness / 2
	makePart("Floor", size, Vector3.new(0, centerY, 0), Config.FieldColor, MATERIAL_FLOOR, field)
end

-- 水:ゆかの上の、浅くて薄い半透明の板。当たり判定なし(歩く高さや、天敵の足元には影響しない)
local function buildWater(field: Folder)
	local size = Vector3.new(Config.FieldSize, Config.WaterDepth, Config.FieldSize)
	local centerY = Config.FieldFloorTopY + Config.WaterDepth / 2
	local water = makePart("Water", size, Vector3.new(0, centerY, 0), Config.WaterColor, MATERIAL_WATER, field)
	water.Transparency = Config.WaterTransparency
	water.Reflectance = Config.WaterReflectance
	water.CanCollide = false
	water.CanQuery = false
	water.CanTouch = false
	water.CastShadow = false
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
	makePart("WallNorth", alongX, Vector3.new(0, centerY, -offset), Config.WallColor, MATERIAL_WALL, field)
	makePart("WallSouth", alongX, Vector3.new(0, centerY, offset), Config.WallColor, MATERIAL_WALL, field)
	makePart("WallEast", alongZ, Vector3.new(offset, centerY, 0), Config.WallColor, MATERIAL_WALL, field)
	makePart("WallWest", alongZ, Vector3.new(-offset, centerY, 0), Config.WallColor, MATERIAL_WALL, field)
end

-- ===== 稲 =====

-- 稲の部品を1つ作る。固定(Anchored)で、当たり判定・探索・接触は全部なし
local function makeRicePart(name: string, material: Enum.Material, color: Color3, parent: Instance): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Material = material
	part.Color = color
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Size = Vector3.new(Config.RiceBladeWidth, 1, Config.RiceBladeThickness)
	part.Parent = parent
	return part
end

-- 葉1枚の向きと傾きを、乱数で決めて作る。index は 1 〜 葉の数、baseYaw は株ごとの回転のずれ
local function createBlade(index: number, baseYaw: number, random: Random, parent: Instance): Blade
	local spread = (index - 1) * (2 * math.pi / Config.RiceBladeCount) -- 葉を、ぐるりと均等に開く
	local yaw = baseYaw + spread + random:NextNumber(-Config.RiceBladeYawJitter, Config.RiceBladeYawJitter)
	local tilt = math.rad(random:NextNumber(Config.RiceBladeTiltMinDeg, Config.RiceBladeTiltMaxDeg))
	local yawCFrame = CFrame.Angles(0, yaw, 0)
	return {
		Part = makeRicePart("Blade", MATERIAL_BLADE, Config.RiceGreenColor, parent),
		Rotation = yawCFrame * CFrame.Angles(tilt, 0, 0),
		Heading = yawCFrame * Vector3.zAxis,
		CosTilt = math.cos(tilt),
		LengthFactor = random:NextNumber(Config.RiceBladeLengthFactorMin, Config.RiceBladeLengthFactorMax),
	}
end

-- 穂1本を作る(最初は透明)
local function createEar(bladeIndex: number, parent: Instance): Ear
	local part = makeRicePart("Ear", MATERIAL_EAR, Config.RiceEarColor, parent)
	part.Shape = Enum.PartType.Cylinder -- 円柱。長さは Size.X の向き
	part.Transparency = 1
	return { Part = part, BladeIndex = bladeIndex }
end

-- 株1つを作る(位置の中心 x, z。乱数 random で向きなどを決める)
local function createPlant(x: number, z: number, random: Random, parent: Instance): Plant
	local baseYaw = random:NextNumber(0, 2 * math.pi)
	local blades: { Blade } = {}
	for index = 1, Config.RiceBladeCount do
		table.insert(blades, createBlade(index, baseYaw, random, parent))
	end
	local ears: { Ear } = {}
	for index = 1, math.min(Config.RiceEarCount, Config.RiceBladeCount) do
		table.insert(ears, createEar(index, parent))
	end
	local variation = Config.RiceHeightVariation
	return {
		X = x,
		Z = z,
		HeightFactor = 1 + random:NextNumber(-variation, variation),
		Blades = blades,
		Ears = ears,
		Cut = false,
	}
end

-- 値が違うときだけ変える(同じ値の代入を飛ばして、軽くする)
local function setBladeLook(blade: Blade, base: Vector3, height: number, color: Color3)
	local part = blade.Part
	local length = height * blade.LengthFactor / blade.CosTilt -- 傾いても、高さが height になる長さ
	local size = Vector3.new(Config.RiceBladeWidth, length, Config.RiceBladeThickness)
	local center = base + blade.Rotation.UpVector * (length / 2) -- 根もとが base につくように置く
	local cframe = CFrame.new(center) * blade.Rotation
	if part.Size ~= size then
		part.Size = size
	end
	if part.CFrame ~= cframe then
		part.CFrame = cframe
	end
	if part.Color ~= color then
		part.Color = color
	end
end

-- 穂を隠す(透明にする)
local function hideEar(ear: Ear)
	if ear.Part.Transparency ~= 1 then
		ear.Part.Transparency = 1
	end
end

-- 穂1本を、葉の先から生やす。earProgress(0〜1)が大きいほど、長く、下に垂れる
local function setEarLook(ear: Ear, plant: Plant, base: Vector3, height: number, earProgress: number)
	local blade = plant.Blades[ear.BladeIndex]
	local length = height * blade.LengthFactor / blade.CosTilt
	local tip = base + blade.Rotation.UpVector * length -- 葉の先
	local droopDeg = Config.RiceEarDroopStartDeg + (Config.RiceEarDroopEndDeg - Config.RiceEarDroopStartDeg) * earProgress
	-- 0度や180度だと外積が 0 になるので、1〜179度の間に収める(130度のときは、そのまま使われる)
	local droop = math.rad(math.clamp(droopDeg, 1, 179))
	-- 穂の向き:真上から droop だけ、葉の倒れる向きへ傾ける。
	-- sin(droop) は 1〜179度で必ずプラスなので、向きは葉の倒れる側のまま(逆にならない)。130度では下向き気味になる
	local direction = blade.Heading * math.sin(droop) + Vector3.yAxis * math.cos(droop)
	local earLength = Config.RiceEarLength * earProgress
	local side = direction:Cross(Vector3.yAxis).Unit -- 外積の大きさは sin(droop)。1〜179度なら 0 にならない
	local up = side:Cross(direction)
	local cframe = CFrame.fromMatrix(tip + direction * (earLength / 2), direction, up)
	local size = Vector3.new(earLength, Config.RiceEarThickness, Config.RiceEarThickness)
	local part = ear.Part
	if part.Size ~= size then
		part.Size = size
	end
	if part.CFrame ~= cframe then
		part.CFrame = cframe
	end
	if part.Transparency ~= 0 then
		part.Transparency = 0
	end
end

-- 株1つの見た目をまとめて決める。earProgress が 0 以下なら、穂は隠す
local function applyPlantLook(plant: Plant, height: number, color: Color3, earProgress: number)
	local base = Vector3.new(plant.X, Config.FieldFloorTopY, plant.Z)
	for _, blade in plant.Blades do
		setBladeLook(blade, base, height, color)
	end
	for _, ear in plant.Ears do
		if earProgress > 0 then
			setEarLook(ear, plant, base, height, earProgress)
		else
			hideEar(ear)
		end
	end
end

-- 育ち具合(0〜1)から、稲の色を決める:緑 → 黄緑 → 黄金
local function calcRiceColor(progress: number): Color3
	local mid = math.clamp(Config.RiceColorMidProgress, 0.01, 0.99) -- 0 や 1 だと割り算が壊れるので、端は避ける
	if progress < mid then
		return Config.RiceGreenColor:Lerp(Config.RiceYellowGreenColor, progress / mid)
	end
	return Config.RiceYellowGreenColor:Lerp(Config.RiceGoldColor, (progress - mid) / (1 - mid))
end

-- 育ち具合(0〜1)から、穂の進み具合(0〜1)を決める。穂は、段階3の始まりから現れる
local function calcEarProgress(progress: number): number
	local earStart = Config.GrowthStageSeconds[2] / Config.RoundSeconds
	if progress <= earStart then
		return 0
	end
	local span = math.max(1 - earStart, 0.001) -- 出穂の始まりが 1 以上でも、ゼロ割りにならないようにする
	return math.clamp((progress - earStart) / span, 0, 1)
end

-- 稲:格子状に株を並べる。位置に少しランダムなずれをつける。
-- 乱数は種を固定するので、やり直しても同じ配置になる
local function buildRice(field: Folder)
	local riceFolder = Instance.new("Folder")
	riceFolder.Name = "Rice"

	local random = Random.new(Config.RiceRandomSeed)
	local spacing = Config.RiceSpacing
	gridCount = math.floor(Config.FieldSize / spacing) -- 1列の株の数
	gridOffset = (gridCount + 1) / 2
	local jitter = Config.RiceJitter
	for ix = 1, gridCount do
		local column: { [number]: Plant } = {}
		plantGrid[ix] = column
		for iz = 1, gridCount do
			local x = (ix - gridOffset) * spacing + random:NextNumber(-jitter, jitter)
			local z = (iz - gridOffset) * spacing + random:NextNumber(-jitter, jitter)
			local plant = createPlant(x, z, random, riceFolder)
			column[iz] = plant
			table.insert(allPlants, plant)
		end
	end
	riceFolder.Parent = field
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

-- 稲の育ち具合(0〜1)に合わせて、高さ・色・穂を変える。刈られた株は変えない。
-- 数千の値を変えるので、毎フレームは呼ばない(RoundService が RiceGrowthUpdateSeconds ごとに呼ぶ)
function FieldService.SetGrowthProgress(progress: number)
	local clamped = math.clamp(progress, 0, 1)
	if clamped == lastProgress then
		return
	end
	lastProgress = clamped

	local baseHeight = Config.RiceHeightMin + (Config.RiceHeightMax - Config.RiceHeightMin) * clamped
	local color = calcRiceColor(clamped)
	local earProgress = calcEarProgress(clamped)
	for _, plant in allPlants do
		if not plant.Cut then
			applyPlantLook(plant, baseHeight * plant.HeightFactor, color, earProgress)
		end
	end
end

-- 株を刈り株にする(すでに刈っていたら何もしない)
local function cutPlant(plant: Plant)
	if plant.Cut then
		return
	end
	plant.Cut = true
	anyCut = true
	applyPlantLook(plant, Config.RiceStubbleHeight, Config.RiceStubbleColor, 0)
end

-- 向きのついた長方形の中に、中心が入る株を刈る。
-- cframe は長方形の中心の位置と向き(横が X、前後が Z)。width は横幅、length は前後の長さ。
-- 長方形を囲む四角の範囲の格子だけを調べる(田んぼ全体は調べない)
function FieldService.CutRice(cframe: CFrame, width: number, length: number)
	if gridCount == 0 then
		return
	end
	local halfWidth = width / 2
	local halfLength = length / 2

	-- 長方形の4つの角から、ワールドでの外接の四角を出す
	local minX = math.huge
	local maxX = -math.huge
	local minZ = math.huge
	local maxZ = -math.huge
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			local corner = cframe * Vector3.new(sx * halfWidth, 0, sz * halfLength)
			minX = math.min(minX, corner.X)
			maxX = math.max(maxX, corner.X)
			minZ = math.min(minZ, corner.Z)
			maxZ = math.max(maxZ, corner.Z)
		end
	end

	-- 外接の四角が覆う格子の番号の範囲(ずれの分だけ広めに見る)
	local spacing = Config.RiceSpacing
	local jitter = Config.RiceJitter
	local ixFrom = math.max(1, math.floor((minX - jitter) / spacing + gridOffset))
	local ixTo = math.min(gridCount, math.ceil((maxX + jitter) / spacing + gridOffset))
	local izFrom = math.max(1, math.floor((minZ - jitter) / spacing + gridOffset))
	local izTo = math.min(gridCount, math.ceil((maxZ + jitter) / spacing + gridOffset))

	local y = cframe.Position.Y -- 高さは見ないので、長方形と同じ高さで調べる
	for ix = ixFrom, ixTo do
		local column = plantGrid[ix]
		if column then
			for iz = izFrom, izTo do
				local plant = column[iz]
				if plant and not plant.Cut then
					local localPoint = cframe:PointToObjectSpace(Vector3.new(plant.X, y, plant.Z))
					if math.abs(localPoint.X) <= halfWidth and math.abs(localPoint.Z) <= halfLength then
						cutPlant(plant)
					end
				end
			end
		end
	end
end

-- すべての株を、刈っていない状態に戻し、育ち具合 0 の見た目にする
function FieldService.ResetRice()
	if not anyCut and lastProgress == 0 then
		return -- すでに最初の状態
	end
	for _, plant in allPlants do
		plant.Cut = false
	end
	anyCut = false
	lastProgress = -1 -- 同じ値でも作業が飛ばされないようにする
	FieldService.SetGrowthProgress(0)
end

-- 田んぼ全体を作る(ゲーム開始時に1回だけ呼ぶ)
function FieldService.Build()
	local old = Workspace:FindFirstChild("Field")
	if old then
		old:Destroy()
	end
	table.clear(allPlants)
	table.clear(plantGrid)
	gridCount = 0
	lastProgress = -1
	anyCut = false

	local field = Instance.new("Folder")
	field.Name = "Field"
	buildFloor(field)
	buildWater(field)
	buildWalls(field)
	buildRice(field)
	buildSpawn(field)

	-- 先に育ち具合 0 の見た目を作ってから Workspace に入れる(部品が原点にある状態を、見せない)
	FieldService.SetGrowthProgress(0)
	field.Parent = Workspace
	disableDefaultSpawns()
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
