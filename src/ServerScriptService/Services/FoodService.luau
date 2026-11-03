--!strict
-- 餌(エサ)を田んぼに置いて、食べる判定をサーバーで行う部品。仕様書 012 の 1。
-- 餌は図形(橙色の丸)だけで作る。外部の素材は使わない。
-- 上下のゆれは、通信が増えるので作らない(仕様書では任意)。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local CrayfishService = require(script.Parent.CrayfishService)
local FieldService = require(script.Parent.FieldService)
local WarnOnce = require(script.Parent.Enemy.WarnOnce)
local RoundService = require(script.Parent.RoundService)
local ScoreService = require(script.Parent.ScoreService)

local FOLDER_NAME = "Food"

type Food = {
	Part: BasePart,
	Position: Vector3, -- 置いた位置(判定に使う)
}

local FoodService = {}

local random = Random.new()
local foods: { [number]: Food } = {} -- 番号 → 餌。食べたら、その場で表から消す(2人が同時に食べないため)
local foodCount = 0 -- 表にある餌の数
local nextId = 0
local generation = 0 -- 世代。やり直すたびに進める。古い世代のタイマーは何もしない
local pendingRespawns = 0 -- 「あとで出す」タイマーが、いま待っている数(今の世代ぶん)
local folder: Folder? = nil
local started = false

-- 餌を入れるフォルダ(無ければ作る)
local function getFolder(): Folder
	local current = folder
	if current ~= nil and current.Parent ~= nil then
		return current
	end
	local created = Instance.new("Folder")
	created.Name = FOLDER_NAME
	created.Parent = Workspace
	folder = created
	return created
end

-- position が、ほかの餌から minSpacing 以上はなれているか(横方向)
local function isSpaced(position: Vector3, minSpacing: number): boolean
	for _, food in foods do
		local dx = food.Position.X - position.X
		local dz = food.Position.Z - position.Z
		if math.sqrt(dx * dx + dz * dz) < minSpacing then
			return false
		end
	end
	return true
end

local function randomPosition(): Vector3
	local bounds = FieldService.GetFieldBounds()
	local half = math.max(0, Config.FieldSize / 2 - Config.FoodWallMargin)
	local x = bounds.Center.X + random:NextNumber(-half, half)
	local z = bounds.Center.Z + random:NextNumber(-half, half)
	return Vector3.new(x, bounds.Center.Y + Config.FoodHoverHeight, z)
end

-- 置く位置を決める。何度か試して、だめなら、間隔の条件をゆるめる(壁からの距離は守る)
local function choosePosition(): Vector3
	local position = randomPosition()
	for _ = 1, Config.FoodPlaceTries do
		if isSpaced(position, Config.FoodMinSpacing) then
			return position
		end
		position = randomPosition()
	end
	return position
end

local function createPart(position: Vector3): Part
	local part = Instance.new("Part")
	part.Name = "Food"
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.new(Config.FoodSize, Config.FoodSize, Config.FoodSize)
	part.Color = Config.FoodColor
	part.Material = Enum.Material.Neon
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Position = position
	part.Parent = getFolder()
	return part
end

-- 餌を1つ置く
local function placeFood()
	local position = choosePosition()
	nextId += 1
	foods[nextId] = { Part = createPart(position), Position = position }
	foodCount += 1
end

-- すべての餌を消す
local function clearFoods()
	for id, food in foods do
		foods[id] = nil
		food.Part:Destroy()
	end
	foodCount = 0
end

-- 餌の数が足りないぶんを置く。reserved は「あとで出すと決まっている数」(その分は、いまは置かない)。
-- foodCount が FoodCount - reserved 未満の間だけ置くので、上限(FoodCount)は超えない
local function fillFoods(reserved: number)
	while foodCount < Config.FoodCount - reserved do
		placeFood()
	end
end

-- 食べた餌の代わりを、少し待ってから出す。世代が変わっていたら(やり直しなど)、何もしない。
-- 置くのに失敗しても止まらない。足りないぶんは、次のタイマーが補う
local function scheduleRespawn()
	local myGeneration = generation
	pendingRespawns += 1
	task.delay(Config.FoodRespawnSeconds, function()
		if myGeneration ~= generation then
			return -- やり直しで、このタイマーは無効(pendingRespawns も 0 に戻っている)
		end
		pendingRespawns = math.max(0, pendingRespawns - 1)
		local ok, err = pcall(fillFoods, pendingRespawns)
		if not ok then
			WarnOnce.Warn("FoodRespawn", `[FoodService] 餌を置けませんでした: {err}`)
		end
	end)
end

-- 全部を置き直す(「もう一度」のとき)
local function resetFoods()
	generation += 1
	pendingRespawns = 0
	clearFoods()
	fillFoods(0)
end

-- プレイヤーの横方向の位置。キャラクターが無いなど、分からないときは nil
local function getPlayerPosition(player: Player): Vector3?
	local character = player.Character
	if not character then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return nil
	end
	return root.Position
end

-- 1人ぶんの、食べる判定。
-- 点が入ったとき(AddFood が true)だけ、餌を食べたことにする。
-- AddFood から表の更新までは、待ちが入らないので、ほかの人が同じ餌を同時に食べることはない
local function tryEat(player: Player)
	if not RoundService.IsPlaying(player) or CrayfishService.IsHidden(player) then
		return
	end
	local origin = getPlayerPosition(player)
	if origin == nil then
		return
	end
	for id, food in foods do
		local dx = food.Position.X - origin.X
		local dz = food.Position.Z - origin.Z
		if math.sqrt(dx * dx + dz * dz) <= Config.FoodEatDistance then
			if not ScoreService.AddFood(player) then
				return -- 点が入らない(いまは食べられない)。餌はそのまま残す
			end
			foods[id] = nil -- 表から消す
			foodCount -= 1
			food.Part:Destroy()
			scheduleRespawn()
		end
	end
end

-- 食べる判定をくり返す。1回の失敗(エラー)で、ループが止まらないよう pcall で包む
local function eatLoop()
	while true do
		task.wait(Config.FoodEatCheckSeconds)
		for _, player in Players:GetPlayers() do
			local ok, err = pcall(tryEat, player)
			if not ok then
				WarnOnce.Warn("FoodEat", `[FoodService] 食べる判定でエラーが出ました: {err}`)
			end
		end
	end
end

function FoodService.Start()
	if started then
		return
	end
	started = true

	local old = Workspace:FindFirstChild(FOLDER_NAME)
	if old then
		old:Destroy()
	end
	folder = nil
	resetFoods()

	RoundService.OnRestart(resetFoods)
	task.spawn(eatLoop)
end

return FoodService
