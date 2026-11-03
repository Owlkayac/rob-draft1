--!strict
-- 風で稲がゆれる(仕様書 008)。クライアント(自分の端末)だけで動かす。
-- 流れ: 自分のキャラクターの近くの株を選ぶ → 株の根もと(Root)を中心に、株の部品ぜんたいを同じ角度で傾ける。
-- サーバーの部品は動かさない(クライアントが書いた位置は、この端末だけに見える)。新しい通信も足さない。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

local RiceSwayController = {}

local TWO_PI = 2 * math.pi
local PLANT_PREFIX = "Plant_" -- 株の Folder の名前の始まり
local MIN_POSITIVE = 0.001 -- 割り算の下の数がこれより小さくならないようにする下限(Config が 0 でも、0 で割らない)
local HIDDEN_TRANSPARENCY = 1 -- この透明度の部品は見えない(出穂の前の穂)。ゆらさない
-- 強風の強弱の形。ゆっくりした波(主)に、ちがう周期の波(副)を足して、規則的に見えないようにする。
-- 2つの重みの合計が 1 なので、強弱は 0〜1 の範囲に収まる
local GUST_MAIN_WEIGHT = 0.7
local GUST_SUB_WEIGHT = 0.3
local GUST_SUB_SPEED = 2.3 -- 副の波の速さ(主の何倍か)
local GUST_SUB_OFFSET = 1.7 -- 副の波のずらし(ラジアン)

-- 部品1つの記録
type PartEntry = {
	Part: BasePart,
	Base: CFrame, -- サーバーが決めた位置(ゆらす前の元の位置)
	Last: CFrame, -- このクライアントが最後に書いた位置(サーバーが変えたかの判定に使う)
}

-- 株1つの記録
type PlantEntry = {
	Folder: Folder,
	Root: Vector3, -- 株の根もと
	Phase: number, -- 波のタイミングのずれ(ラジアン)
	Parts: { PartEntry },
	Lookup: { [Instance]: PartEntry }, -- 部品から記録を探す表
	Dirty: boolean, -- 部品の一覧を作り直す必要があるか
	Active: boolean, -- 部品をゆらした状態(元の位置からずれている)か
	Connections: { RBXScriptConnection },
}

local plants: { [Instance]: PlantEntry } = {} -- 株の Folder → 記録
local currentRice: Instance? = nil -- いま見ている Rice
local riceConnections: { RBXScriptConnection } = {}
local heartbeatConnection: RBXScriptConnection? = nil
local fieldConnection: RBXScriptConnection? = nil
local attachToken = 0 -- 古い待ちを無効にするための番号
local sinceUpdate = 0 -- 前の更新からの経過時間(秒)

local localPlayer = Players.LocalPlayer

-- 0 や負の数を、小さな正の数に直す(割り算の安全のため)
local function atLeastPositive(value: number): number
	return math.max(value, MIN_POSITIVE)
end

-- 風の向き(度)から、水平の向きベクトル(長さ1)を出す。0度 = +Z の向き、90度 = +X の向き
local function windDirection(deg: number): Vector3
	local rad = math.rad(deg)
	return Vector3.new(math.sin(rad), 0, math.cos(rad))
end

local function disconnectAll(list: { RBXScriptConnection })
	for _, connection in list do
		connection:Disconnect()
	end
	table.clear(list)
end

-- 株の部品の一覧を作り直す(すでに知っている部品は、記録をそのまま引き継ぐ)
local function rebuildParts(entry: PlantEntry)
	local newParts: { PartEntry } = {}
	local newLookup: { [Instance]: PartEntry } = {}
	for _, child in entry.Folder:GetChildren() do
		if child:IsA("BasePart") then
			local part = child :: BasePart
			local partEntry = entry.Lookup[part]
			if not partEntry then
				partEntry = { Part = part, Base = part.CFrame, Last = part.CFrame }
			end
			table.insert(newParts, partEntry :: PartEntry)
			newLookup[part] = partEntry
		end
	end
	entry.Parts = newParts
	entry.Lookup = newLookup
	entry.Dirty = false
end

-- 株を表に入れる。Root がない・型がちがう Folder は、無視する
local function registerPlant(child: Instance)
	if plants[child] or not child:IsA("Folder") then
		return
	end
	if string.sub(child.Name, 1, #PLANT_PREFIX) ~= PLANT_PREFIX then
		return
	end
	local rootValue = child:GetAttribute("Root")
	if typeof(rootValue) ~= "Vector3" then
		return
	end
	local root = rootValue :: Vector3
	local folder = child :: Folder
	local baseDirection = windDirection(Config.RiceWindDirectionDeg)
	local entry: PlantEntry = {
		Folder = folder,
		Root = root,
		Phase = root:Dot(baseDirection) / atLeastPositive(Config.RiceWindWaveLength) * TWO_PI, -- 風の向きに沿って、位相がずれる
		Parts = {},
		Lookup = {},
		Dirty = true,
		Active = false,
		Connections = {},
	}
	-- 部品が足されたり消えたりしたら、あとで一覧を作り直す
	table.insert(
		entry.Connections,
		folder.ChildAdded:Connect(function()
			entry.Dirty = true
		end)
	)
	table.insert(
		entry.Connections,
		folder.ChildRemoved:Connect(function()
			entry.Dirty = true
		end)
	)
	rebuildParts(entry)
	plants[folder] = entry
end

-- 株を表から消す(つないだものも切って、メモリを残さない)
local function removePlant(folder: Instance)
	local entry = plants[folder]
	if entry then
		disconnectAll(entry.Connections)
		plants[folder] = nil
	end
end

-- 見ている Rice をやめて、表を空にする。attachToken は変えない
-- (新しい Field を待っている最中の待ちを、巻き込んで捨てないため)
local function clearRice()
	disconnectAll(riceConnections)
	for folder in plants do
		removePlant(folder)
	end
	currentRice = nil
end

-- 待っている最中の古い待ちを、すべて無効にする(Stop のときなど)。見ている Rice もやめる
local function detachRice()
	attachToken += 1
	clearRice()
end

-- Rice を見はじめる。すでにある株を拾い、あとから足される株も拾う
local function attachRice(rice: Instance)
	clearRice()
	currentRice = rice
	for _, child in rice:GetChildren() do
		registerPlant(child)
	end
	table.insert(riceConnections, rice.ChildAdded:Connect(registerPlant))
	table.insert(riceConnections, rice.ChildRemoved:Connect(removePlant))
end

-- Field が現れたら、Rice を待って見はじめる。待っている間に、さらに別の Field が来たら、古い待ちはやめる
-- (attachToken を増やすのは、ここ(新しい Field の差し替え)と Stop だけ)
local function waitAndAttach(field: Instance)
	attachToken += 1
	local token = attachToken
	local rice = field:WaitForChild("Rice", Config.CharacterWaitSeconds)
	if token ~= attachToken then
		return
	end
	if not rice then
		warn("[RiceSwayController] Field/Rice が見つかりません。稲はゆれません。")
		return
	end
	attachRice(rice)
end

-- サーバーが部品を変えていたら、その位置を新しい「元の位置」として覚え直す。
-- 書いた位置と読んだ位置はわずかにずれることがあるので、「大きく違うとき」だけ、変えたとみなす
local function syncBase(partEntry: PartEntry)
	local current = partEntry.Part.CFrame
	local last = partEntry.Last
	local moved = (current.Position - last.Position).Magnitude > Config.RiceSwayRebaseDistance
	local turned = current.XVector:Dot(last.XVector) < Config.RiceSwayRebaseDot
		or current.YVector:Dot(last.YVector) < Config.RiceSwayRebaseDot
	if moved or turned then
		partEntry.Base = current
		partEntry.Last = current
	end
end

-- 部品に位置を書き、書いた位置を覚える
local function writePart(partEntry: PartEntry, cframe: CFrame)
	partEntry.Part.CFrame = cframe
	partEntry.Last = cframe
end

-- 株ぜんたいを、根もとを中心に傾ける。axis は傾ける回転軸、angle は傾き(ラジアン)
local function swayPlant(entry: PlantEntry, axis: Vector3, angle: number)
	local rotation = CFrame.fromAxisAngle(axis, angle)
	local pivot = CFrame.new(entry.Root) * rotation * CFrame.new(-entry.Root) -- 根もとを中心にした回転
	for _, partEntry in entry.Parts do
		-- 見えない部品(出穂の前の穂)は、位置を書かない。見えるようになったら、次の更新から含まれる
		if partEntry.Part.Transparency ~= HIDDEN_TRANSPARENCY then
			syncBase(partEntry)
			writePart(partEntry, pivot * partEntry.Base)
		end
	end
	entry.Active = true
end

-- 株を元の位置に戻す
local function restorePlant(entry: PlantEntry)
	for _, partEntry in entry.Parts do
		syncBase(partEntry)
		if partEntry.Part.CFrame ~= partEntry.Base then
			writePart(partEntry, partEntry.Base)
		end
	end
	entry.Active = false
end

-- 時刻 t の、強風の強さの割合(RiceWindGustMin 〜 RiceWindGustMax)
local function gustStrength(t: number): number
	local wave = TWO_PI * t / atLeastPositive(Config.RiceWindGustPeriodSeconds)
	local mix = GUST_MAIN_WEIGHT * math.sin(wave) + GUST_SUB_WEIGHT * math.sin(wave * GUST_SUB_SPEED + GUST_SUB_OFFSET)
	local ratio = 0.5 + 0.5 * mix -- 0〜1
	return Config.RiceWindGustMin + (Config.RiceWindGustMax - Config.RiceWindGustMin) * ratio
end

-- 自分のキャラクターの位置。まだいない・消えているときは nil
local function getCenter(): Vector3?
	local character = localPlayer.Character
	if not character then
		return nil
	end
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart or not rootPart:IsA("BasePart") then
		return nil
	end
	return (rootPart :: BasePart).Position
end

-- 1回の更新:範囲の中の株をゆらし、外に出た株を戻す
local function updateAll()
	local rice = currentRice
	if rice and not rice:IsDescendantOf(Workspace) then
		clearRice() -- 田んぼが作り直された。新しい Field は fieldConnection が拾う(待ち中の番号は変えない)
		return
	end
	local center = getCenter()
	if not center then
		return
	end

	local t = os.clock()
	local direction = windDirection(
		Config.RiceWindDirectionDeg
			+ Config.RiceWindDirWobbleDeg * math.sin(TWO_PI * t / atLeastPositive(Config.RiceWindDirWobblePeriodSeconds))
	)
	local axis = Vector3.yAxis:Cross(direction) -- この軸で正の向きに回すと、先が風下へ傾く
	local amplitude = math.rad(Config.RiceSwayMaxDeg) * gustStrength(t)
	local wave = TWO_PI * t / atLeastPositive(Config.RiceSwayPeriodSeconds)
	local radiusSquared = Config.RiceSwayRadius * Config.RiceSwayRadius

	for folder, entry in plants do
		if folder.Parent ~= rice then
			removePlant(folder)
		else
			if entry.Dirty then
				rebuildParts(entry)
			end
			local dx = entry.Root.X - center.X
			local dz = entry.Root.Z - center.Z
			local near = dx * dx + dz * dz <= radiusSquared
			-- 範囲の外の株では、Attribute を読まない(近い株のときだけ読む)
			if near and folder:GetAttribute("Cut") ~= true then
				-- 傾きは 0〜最大 の間で、風下側だけ。風下に傾いて、戻る。
				-- sin(wave - 位相) は、位相が大きい(風下の)株ほど、あとで山が来る = 波が風下へ流れる
				local lean = 0.5 + 0.5 * math.sin(wave - entry.Phase)
				swayPlant(entry, axis, amplitude * lean)
			elseif entry.Active then
				restorePlant(entry)
			end
		end
	end
end

-- 毎フレーム呼ばれる。RiceSwayHz ごとにだけ更新する
local function onHeartbeat(dt: number)
	local interval = 1 / atLeastPositive(Config.RiceSwayHz)
	sinceUpdate += dt
	if sinceUpdate < interval then
		return
	end
	-- 余りを引いて、平均が RiceSwayHz に近くなるようにする。遅れがたまりすぎたら、ゼロに戻す
	sinceUpdate = if sinceUpdate > interval * 2 then 0 else sinceUpdate - interval
	updateAll()
end

function RiceSwayController.Start()
	if heartbeatConnection then
		return -- 二重に起動しない
	end
	heartbeatConnection = RunService.Heartbeat:Connect(onHeartbeat)
	-- 田んぼが作り直されて、新しい Field が現れたときに、拾い直す
	fieldConnection = Workspace.ChildAdded:Connect(function(child: Instance)
		if child.Name == "Field" then
			task.spawn(waitAndAttach, child)
		end
	end)
	-- 最初の Field を待つ(待ちが長くなっても、ほかの起動を止めない)
	task.spawn(function()
		local field = Workspace:WaitForChild("Field", Config.CharacterWaitSeconds)
		if not field then
			warn("[RiceSwayController] Field が見つかりません。稲はゆれません。")
			return
		end
		if not currentRice then
			waitAndAttach(field)
		end
	end)
end

-- 止めて、ゆらした株を元に戻す(このゲームでは普段は呼ばない)
function RiceSwayController.Stop()
	if heartbeatConnection then
		heartbeatConnection:Disconnect()
		heartbeatConnection = nil
	end
	if fieldConnection then
		fieldConnection:Disconnect()
		fieldConnection = nil
	end
	for _, entry in plants do
		if entry.Active then
			restorePlant(entry)
		end
	end
	detachRice()
	sinceUpdate = 0
end

return RiceSwayController
