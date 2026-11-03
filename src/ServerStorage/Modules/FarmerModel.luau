--!strict
-- 農家さんの「見た目」だけを作る部品。動きの判断は EnemyService が行う。(仕様書 002)
-- 外部の素材は使わず、Roblox 標準の人型(R15)と、図形の麦わら帽子で作る。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)

local FarmerModel = {}

-- 肌と作業着の色を決めた HumanoidDescription(人型の設計図)を作る
local function makeDescription(): HumanoidDescription
	local description = Instance.new("HumanoidDescription")
	-- 頭と腕は肌の色
	description.HeadColor = Config.FarmerSkinColor
	description.LeftArmColor = Config.FarmerSkinColor
	description.RightArmColor = Config.FarmerSkinColor
	-- 胴と足は作業着の色
	description.TorsoColor = Config.FarmerClothesColor
	description.LeftLegColor = Config.FarmerClothesColor
	description.RightLegColor = Config.FarmerClothesColor
	return description
end

-- つぶした円柱(Part)を1つ作る。円柱は X 方向が「高さ」なので、立てるために90度回す
local function makeDisc(name: string, height: number, diameter: number, head: BasePart, centerOffsetY: number): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Shape = Enum.PartType.Cylinder
	part.Size = Vector3.new(height, diameter, diameter)
	part.Color = Config.FarmerHatColor
	part.Material = Enum.Material.SmoothPlastic
	part.CanCollide = false -- 歩く邪魔にならないように
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.CFrame = head.CFrame * CFrame.new(0, centerOffsetY, 0) * CFrame.Angles(0, 0, math.rad(90))

	-- 頭にくっつける(WeldConstraint)
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = head
	weld.Part1 = part
	weld.Parent = part
	return part
end

-- 麦わら帽子(つば+山)を頭につける
local function attachHat(model: Model)
	local head = model:FindFirstChild("Head")
	if not head or not head:IsA("BasePart") then
		warn("[FarmerModel] Head が見つからないので、帽子をつけられません")
		return
	end
	local headTop = head.Size.Y / 2
	local brimThickness = Config.FarmerHatBrimThickness
	local crownHeight = Config.FarmerHatCrownHeight

	-- つば:頭のてっぺんの上に、うすく広く
	local brim = makeDisc("HatBrim", brimThickness, Config.FarmerHatBrimDiameter, head, headTop + brimThickness / 2)
	brim.Parent = model
	-- 山:つばの上に、少し細く高く
	local crown = makeDisc("HatCrown", crownHeight, Config.FarmerHatCrownDiameter, head, headTop + brimThickness + crownHeight / 2)
	crown.Parent = model
end

-- 簡単な Part を1つ作る(簡易モデル用)
local function makeBodyPart(name: string, size: Vector3, color: Color3): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	return part
end

-- 2つの Part をくっつける(WeldConstraint)
local function weld(part0: BasePart, part1: BasePart)
	local constraint = Instance.new("WeldConstraint")
	constraint.Part0 = part0
	constraint.Part1 = part1
	constraint.Parent = part1
end

-- 人型の作成に失敗したときの代わり:Part だけで作る簡易な人型
-- (Humanoid、HumanoidRootPart、頭、胴を WeldConstraint でつなぎ、帽子は attachHat でつける)
local function createFallback(): Model
	local model = Instance.new("Model")
	model.Name = "Farmer"

	local rootSize = Config.FarmerFallbackRootSize
	local torsoSize = Config.FarmerFallbackTorsoSize
	local headSize = Config.FarmerFallbackHeadSize

	-- HumanoidRootPart:見えない、動きの中心。原点に置く(あとで PivotTo で動かす)
	local root = makeBodyPart("HumanoidRootPart", rootSize, Config.FarmerClothesColor)
	root.Transparency = 1
	root.CFrame = CFrame.new(0, 0, 0)

	-- 胴:根っこと同じ中心に置く。ほかの Part は、歩く邪魔にならないよう当たり判定を切る
	local torso = makeBodyPart("Torso", torsoSize, Config.FarmerClothesColor)
	torso.CFrame = CFrame.new(0, 0, 0)
	torso.CanCollide = false
	torso.Massless = true

	-- 頭:胴の上にのせる
	local head = makeBodyPart("Head", headSize, Config.FarmerSkinColor)
	head.CFrame = CFrame.new(0, torsoSize.Y / 2 + headSize.Y / 2, 0)
	head.CanCollide = false
	head.Massless = true

	root.Parent = model
	torso.Parent = model
	head.Parent = model
	weld(root, torso)
	weld(torso, head)
	model.PrimaryPart = root

	local humanoid = Instance.new("Humanoid")
	-- 足の裏(胴の底)が地面につくように、HipHeight を決める。
	-- Humanoid は「地面から HipHeight + 根っこの高さの半分」の位置に根っこを置く
	humanoid.HipHeight = torsoSize.Y / 2 - rootSize.Y / 2
	humanoid.Parent = model
	return model
end

-- 本物の人型(R15)の作成を、失敗したら待ってやり直しながら試す。全部失敗したら nil
local function tryCreateHumanoid(): Model?
	for attempt = 1, Config.FarmerCreateMaxAttempts do
		local description = makeDescription()
		local ok, result = pcall(function()
			return Players:CreateHumanoidModelFromDescription(description, Enum.HumanoidRigType.R15)
		end)
		description:Destroy()
		if ok and typeof(result) == "Instance" and result:IsA("Model") then
			return result
		end
		warn(`[FarmerModel] 人型の作成に失敗しました({attempt}/{Config.FarmerCreateMaxAttempts}回目): {result}`)
		if attempt < Config.FarmerCreateMaxAttempts then
			task.wait(Config.FarmerCreateRetryWaitSeconds)
		end
	end
	return nil
end

-- 農家さんのモデルを作って返す(Workspace にはまだ入れない)。
-- 人型の作成は、通信で待つことがある(その間、この関数は止まる)。
-- 何回やっても失敗したら、Part だけの簡易モデルを返す(必ずモデルが返る)
function FarmerModel.Create(): Model
	local model: Model
	local created = tryCreateHumanoid()
	if created then
		model = created
	else
		warn("[FarmerModel] 人型を作れなかったので、Part だけの簡易モデルを使います")
		model = createFallback()
	end
	model.Name = "Farmer"

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None -- 名前を表示しない
		humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff -- 体力バーも出さない
	end
	attachHat(model)
	return model
end

-- 動きの計算をサーバーが持つようにする(Workspace に入れたあとで呼ぶ)
function FarmerModel.ClaimServerOwnership(model: Model)
	local root = model:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") and root:IsDescendantOf(game) then
		pcall(function()
			root:SetNetworkOwner(nil)
		end)
	end
end

return FarmerModel
