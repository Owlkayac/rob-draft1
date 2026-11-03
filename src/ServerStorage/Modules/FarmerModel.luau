--!strict
-- 農家さんの「見た目」だけを作る部品。動きの判断は EnemyService が行う。(仕様書 002)
-- 外部の素材は使わず、Roblox 標準の人型(R15)と、図形の麦わら帽子で作る。
-- 大きさは Config.FarmerScale 倍(仕様書 002 の 8)。足元の高さの補正もここ(PlaceAt)。帽子の大きさの数字は「標準サイズ基準」。
-- 仕様書 016:帽子を作る処理(AddHat)は、巨人になったプレイヤーの頭にもつけられるよう、公開してある。
-- 仕様書 014:頭の上の表示(BillboardGui "StateSign")と、行動の名前を伝える Attribute "EnemyState" もここ(SetState)。

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

-- 帽子の部品の名前(つけ直すとき、古い帽子を消すために使う)
local HAT_PART_NAMES = { "HatBrim", "HatCrown" }

-- 麦わら帽子(つば+山)を、頭(head)につける。農家さんAIと、巨人になったプレイヤー(仕様書 016)の両方が使う。
-- scale は、頭がいま何倍の大きさか(帽子も同じ倍率にする。省略か 0 以下なら 1)。
-- 大きくしたあとで、実際の頭の大きさを見てつけるので、ずれない。
-- 帽子の部品は、head と同じ入れ物(キャラクターやモデル)に入れる。古い帽子があれば、先に消す(二重にならない)
function FarmerModel.AddHat(head: BasePart, scale: number?)
	local parent = head.Parent
	if parent == nil then
		warn("[FarmerModel] 頭が Workspace などに入っていないので、帽子をつけられません")
		return
	end
	local usedScale = if scale ~= nil and scale > 0 then scale else 1
	for _, name in HAT_PART_NAMES do
		local old = parent:FindFirstChild(name)
		if old then
			old:Destroy()
		end
	end
	local headTop = head.Size.Y / 2
	local brimThickness = Config.FarmerHatBrimThickness * usedScale
	local crownHeight = Config.FarmerHatCrownHeight * usedScale
	local brimDiameter = Config.FarmerHatBrimDiameter * usedScale
	local crownDiameter = Config.FarmerHatCrownDiameter * usedScale

	-- つば:頭のてっぺんの上に、うすく広く
	local brim = makeDisc(HAT_PART_NAMES[1], brimThickness, brimDiameter, head, headTop + brimThickness / 2)
	brim.Parent = parent
	-- 山:つばの上に、少し細く高く
	local crown = makeDisc(HAT_PART_NAMES[2], crownHeight, crownDiameter, head, headTop + brimThickness + crownHeight / 2)
	crown.Parent = parent
end

-- 麦わら帽子を、モデルの頭につける(農家さんAI用)。頭がなければ警告して、何もしない
local function attachHat(model: Model, scale: number)
	local head = model:FindFirstChild("Head")
	if not head or not head:IsA("BasePart") then
		warn("[FarmerModel] Head が見つからないので、帽子をつけられません")
		return
	end
	FarmerModel.AddHat(head, scale)
end

-- ===== 頭の上の表示(仕様書 014 の 2) =====
-- 名前:クライアントの演出も、この名前で探すことがある
local SIGN_NAME = "StateSign"
local SIGN_LABEL_NAME = "Label"
-- 行動の名前を入れる Attribute(属性)の名前。Attribute は、モデルにつけられる「名前つきのメモ」で、クライアントも読める
local STATE_ATTRIBUTE_NAME = "EnemyState"

-- 頭の上の表示(BillboardGui = 3D空間に置く、いつもこちらを向く看板)を、頭につける。
-- 大きさ・高さは scale 倍(巨人の頭の上でも読める大きさ)。最初は非表示(Enabled = false)。
-- 頭がなければ、何もしない
local function attachStateSign(model: Model, scale: number)
	local head = model:FindFirstChild("Head")
	if not head or not head:IsA("BasePart") then
		warn("[FarmerModel] Head が見つからないので、頭の上の表示をつけられません")
		return
	end
	local signWidth = Config.FarmerSignSize.X * scale
	local signHeight = Config.FarmerSignSize.Y * scale
	-- 頭の中心から、「頭のてっぺん + 帽子 + すきま + 表示の高さの半分」だけ上
	local hatHeight = (Config.FarmerHatBrimThickness + Config.FarmerHatCrownHeight) * scale
	local offsetY = head.Size.Y / 2 + hatHeight + Config.FarmerSignGap * scale + signHeight / 2

	local gui = Instance.new("BillboardGui")
	gui.Name = SIGN_NAME
	gui.Adornee = head
	gui.AlwaysOnTop = true -- 稲や壁にかくれず、いつも手前に見える
	gui.Size = UDim2.fromScale(signWidth, signHeight) -- Scale は「スタッド」の大きさ
	gui.StudsOffsetWorldSpace = Vector3.new(0, offsetY, 0)
	gui.MaxDistance = Config.FarmerSignMaxDistance
	gui.LightInfluence = 0 -- 暗い時間帯でも、文字は明るいまま
	gui.Enabled = false

	local label = Instance.new("TextLabel")
	label.Name = SIGN_LABEL_NAME
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1 -- 背景なし
	label.TextScaled = true
	label.Font = Enum.Font.GothamBold -- 太い字
	label.Text = Config.FarmerSignAlertText
	label.TextColor3 = Config.FarmerSignAlertColor
	label.TextStrokeColor3 = Config.FarmerSignStrokeColor
	label.TextStrokeTransparency = 0
	label.Parent = gui

	gui.Parent = head
end

-- 表示の文字と色を決めて、見えるようにする
local function showSign(sign: BillboardGui, text: string, color: Color3)
	local label = sign:FindFirstChild(SIGN_LABEL_NAME)
	if label and label:IsA("TextLabel") then
		label.Text = text
		label.TextColor3 = color
	end
	sign.Enabled = true
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
-- scale 倍の大きさで、最初から作る(あとから ScaleTo で大きくはしない)
local function createFallback(scale: number): Model
	local model = Instance.new("Model")
	model.Name = "Farmer"

	local rootSize = Config.FarmerFallbackRootSize * scale
	local torsoSize = Config.FarmerFallbackTorsoSize * scale
	local headSize = Config.FarmerFallbackHeadSize * scale

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
	humanoid.RequiresNeck = false -- 簡易モデルには首の関節(Neck)がないので、首が無くても倒れないようにする
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

-- モデルを Config.FarmerScale 倍にする。戻り値は、実際の倍率(失敗したら 1)
local function scaleModel(model: Model): number
	local ok, err = pcall(function()
		model:ScaleTo(Config.FarmerScale)
	end)
	if not ok then
		warn(`[FarmerModel] 大きくできませんでした(標準の大きさのままにします): {err}`)
		return 1
	end
	local readOk, scale = pcall(function()
		return model:GetScale()
	end)
	if readOk and type(scale) == "number" and scale > 0 then
		return scale
	end
	return Config.FarmerScale
end

-- 農家さんのモデルを作って返す(Workspace にはまだ入れない)。
-- 戻り値は (モデル, 実際に使われた倍率)。大きくするのに失敗したときは、倍率が 1 になる。
-- 人型の作成は、通信で待つことがある(その間、この関数は止まる)。
-- 何回やっても失敗したら、Part だけの簡易モデルを返す(必ずモデルが返る)。
-- 大きさは、できれば Config.FarmerScale 倍。
function FarmerModel.Create(): (Model, number)
	local model: Model
	local scale: number
	local created = tryCreateHumanoid()
	if created then
		model = created
		scale = scaleModel(model)
	else
		warn("[FarmerModel] 人型を作れなかったので、Part だけの簡易モデルを使います")
		scale = Config.FarmerScale
		model = createFallback(scale)
	end
	model.Name = "Farmer"

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None -- 名前を表示しない
		humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff -- 体力バーも出さない
	end
	attachHat(model, scale) -- 大きくしたあとで、同じ倍率の帽子をつける
	attachStateSign(model, scale) -- 頭の上の「!」「?」(最初は非表示)。簡易モデルにも、Head があればつく
	return model, scale
end

-- 「足元の高さ(ワールドのY)」を返す。モデル全体を囲む箱(バウンディングボックス)の底の高さ。
-- 箱の中心の y から、箱の高さの半分を引いて求める。
-- 人型の根っこ(HumanoidRootPart)は足より上にあるので、根っこの位置ではなく、この値を使う
function FarmerModel.GetFootY(model: Model): number
	local boxCFrame, boxSize = model:GetBoundingBox()
	return boxCFrame.Position.Y - boxSize.Y / 2
end

-- モデルを point の横位置(X, Z)に置き、足元が「ゆか上面 + 余裕」の高さになるように補正する。
-- 足元の高さは GetFootY(箱の底)で求めるので、大きさが変わっても、めり込まず、浮かない。
-- Workspace に入れる前でも後でも呼べる
function FarmerModel.PlaceAt(model: Model, point: Vector3)
	local targetFootY = Config.FieldFloorTopY + Config.FarmerSpawnMargin
	local current = model:GetPivot()
	model:PivotTo(CFrame.new(point.X, current.Position.Y, point.Z)) -- まず横位置だけ合わせる
	local diff = targetFootY - FarmerModel.GetFootY(model)
	model:PivotTo(model:GetPivot() + Vector3.new(0, diff, 0)) -- 次に、高さだけを足りない分ずらす
end

-- 行動の名前(Patrol / Notice / Chase / Search)を、Attribute "EnemyState" に入れ、頭の上の表示を切り替える。
-- EnemyService が、行動が切り替わるたびに呼ぶ(Definition.OnBehaviorChanged)。
--   Notice・Chase:赤い「!」 / Search:黄色い「?」 / それ以外(Patrol など):非表示
-- モデルが壊れていて、表示が見つからなくても、エラーにしない
function FarmerModel.SetState(model: Model, stateName: string)
	model:SetAttribute(STATE_ATTRIBUTE_NAME, stateName)
	local sign = model:FindFirstChild(SIGN_NAME, true)
	if not sign or not sign:IsA("BillboardGui") then
		return
	end
	if stateName == "Notice" or stateName == "Chase" then
		showSign(sign, Config.FarmerSignAlertText, Config.FarmerSignAlertColor)
	elseif stateName == "Search" then
		showSign(sign, Config.FarmerSignSearchText, Config.FarmerSignSearchColor)
	else
		sign.Enabled = false
	end
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
