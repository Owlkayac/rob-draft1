--!strict
-- ザリガニの足・はさみ・ひげを動かす(仕様書 010)。クライアント(自分の端末)だけで動かす。
-- 流れ: Workspace の CrayfishVisual を見つける → 中の Motor6D(関節)を名前で分類する →
--       毎フレーム、歩く速さと時間から Transform(関節の回転)を計算して書く。
-- Transform は、この端末だけに効く。サーバーには届かない。新しい通信(RemoteEvent)も足さない。
-- 他のプレイヤーのザリガニも、同じ仕組みで動かす(見えている CrayfishVisual すべてが対象)。
--
-- 関節の向き(CrayfishModel で、ザリガニの向きに合わせてある): X=右、Y=上、Z=後ろ(前が -Z)
--   足:   Y軸まわりに回す → 足先が前後にふれる
--   はさみ: X軸まわりに回す → 先が上下にゆれる(プラスで上)
--   ひげ:   X軸まわり(下向きにたなびく)と、Y軸まわり(ふるえ)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

local CrayfishAnimator = {}

local VISUAL_FOLDER_NAME = "CrayfishVisual" -- CrayfishModel と同じ名前
local HIDDEN_ATTRIBUTE = "Hidden" -- 潜っているとき、サーバーがキャラクターにつける目印
local TWO_PI = 2 * math.pi
local MAX_DT = 0.1 -- 1フレームの時間の上限(重いときに、急に飛ばないように)
local MIN_POSITIVE = 0.001 -- 割り算の下の数がこれより小さくならないようにする下限(Config が 0 でも、0 で割らない)
local SEED_STEP = 1.7 -- キャラクターごとに動きのタイミングをずらす量(ラジアン)

-- 関節1つの記録
type JointEntry = {
	Motor: Motor6D,
	Side: number, -- 左 = -1、右 = 1
	Index: number, -- 足の番号(1〜3)。足以外は 0
}

-- キャラクター1体の記録
type AnimEntry = {
	Visual: Folder, -- CrayfishVisual
	Character: Model,
	Root: BasePart?, -- HumanoidRootPart(見つかったら覚える)
	Legs: { JointEntry },
	Claws: { JointEntry },
	Antennae: { JointEntry },
	Dirty: boolean, -- 関節の一覧を作り直す必要があるか
	Phase: number, -- 足の動きの位相(ラジアン)。歩いた距離に比例して進む
	Walk: number, -- 歩きの度合い(0 = 止まっている、1 = 歩いている。なめらかに変わる)
	Seed: number, -- タイミングのずれ(ラジアン)
	Connections: { RBXScriptConnection },
}

local entries: { [Instance]: AnimEntry } = {} -- CrayfishVisual → 記録
local workspaceConnection: RBXScriptConnection? = nil
local renderConnection: RBXScriptConnection? = nil
local seedCounter = 0

local function sideFromLetter(letter: string): number
	return if letter == "L" then -1 else 1
end

-- 関節の名前を見て、種類ごとの一覧に入れる。知らない名前は無視する
local function classifyMotor(entry: AnimEntry, motor: Motor6D)
	local legSide, legIndex = string.match(motor.Name, "^Leg([LR])(%d+)$")
	if legSide and legIndex then
		table.insert(entry.Legs, { Motor = motor, Side = sideFromLetter(legSide), Index = tonumber(legIndex) or 1 })
		return
	end
	local clawSide = string.match(motor.Name, "^Claw([LR])$")
	if clawSide then
		table.insert(entry.Claws, { Motor = motor, Side = sideFromLetter(clawSide), Index = 0 })
		return
	end
	local antennaSide = string.match(motor.Name, "^Antenna([LR])$")
	if antennaSide then
		table.insert(entry.Antennae, { Motor = motor, Side = sideFromLetter(antennaSide), Index = 0 })
	end
end

-- 関節の一覧を作り直す。Motor6D は、各部品(Part)の子にある(Folder の直下にはない)
local function rebuildJoints(entry: AnimEntry)
	entry.Legs = {}
	entry.Claws = {}
	entry.Antennae = {}
	for _, part in entry.Visual:GetChildren() do
		if part:IsA("BasePart") then
			for _, child in part:GetChildren() do
				if child:IsA("Motor6D") then
					classifyMotor(entry, child)
				end
			end
		end
	end
	entry.Dirty = false
end

-- 記録を消す(つないだものも切って、メモリを残さない)
local function removeEntry(visual: Instance)
	local entry = entries[visual]
	if not entry then
		return
	end
	for _, connection in entry.Connections do
		connection:Disconnect()
	end
	table.clear(entry.Connections)
	entries[visual] = nil
end

-- CrayfishVisual を表に入れる。キャラクター(Model)の中にない Folder は、無視する
local function registerVisual(instance: Instance)
	if entries[instance] or instance.Name ~= VISUAL_FOLDER_NAME or not instance:IsA("Folder") then
		return
	end
	local character = instance.Parent
	if not character or not character:IsA("Model") then
		return
	end
	seedCounter += 1
	local entry: AnimEntry = {
		Visual = instance,
		Character = character,
		Root = nil,
		Legs = {},
		Claws = {},
		Antennae = {},
		Dirty = true,
		Phase = 0,
		Walk = 0,
		Seed = seedCounter * SEED_STEP,
		Connections = {},
	}
	-- 関節が足された・消えたら、あとで一覧を作り直す(サーバーから少しずつ届く場合に備える)
	table.insert(
		entry.Connections,
		instance.DescendantAdded:Connect(function(descendant: Instance)
			if descendant:IsA("Motor6D") then
				entry.Dirty = true
			end
		end)
	)
	table.insert(
		entry.Connections,
		instance.DescendantRemoving:Connect(function(descendant: Instance)
			if descendant:IsA("Motor6D") then
				entry.Dirty = true
			end
		end)
	)
	-- Folder が Workspace から外れたり消えたりしたら、記録を消す
	table.insert(
		entry.Connections,
		instance.AncestryChanged:Connect(function()
			if not instance:IsDescendantOf(Workspace) then
				removeEntry(instance)
			end
		end)
	)
	entries[instance] = entry
end

-- HumanoidRootPart を探す(一度見つけたら覚える。消えたら探し直す)
local function getRoot(entry: AnimEntry): BasePart?
	local root = entry.Root
	if root and root.Parent then
		return root
	end
	local found = entry.Character:FindFirstChild("HumanoidRootPart")
	if found and found:IsA("BasePart") then
		entry.Root = found
		return found
	end
	entry.Root = nil
	return nil
end

-- 水平方向の速さ(スタッド/秒)。上下の動き(ジャンプなど)は含めない
local function horizontalSpeed(root: BasePart): number
	local velocity = root.AssemblyLinearVelocity
	return math.sqrt(velocity.X * velocity.X + velocity.Z * velocity.Z)
end

-- 歩きの度合いと位相を進める。止まっているとき(遅いとき)は、位相は進めない
local function advance(entry: AnimEntry, speed: number, dt: number)
	local moving = speed > Config.CrayfishMoveMinSpeed
	local target = if moving then 1 else 0
	local blend = math.min(1, Config.CrayfishAnimBlendPerSecond * dt)
	entry.Walk += (target - entry.Walk) * blend
	if moving then
		-- 歩いた距離(速さ × dt) × 1スタッドあたりの回数 × 2π
		entry.Phase = (entry.Phase + speed * dt * Config.CrayfishLegCyclesPerStud * TWO_PI) % TWO_PI
	end
end

-- 足を動かす。左右、前後の隣どうしが逆位相(互い違い)になる
local function animateLegs(entry: AnimEntry)
	local swing = math.rad(Config.CrayfishLegSwingDeg) * entry.Walk
	for _, joint in entry.Legs do
		if joint.Motor.Parent then
			local sidePhase = if joint.Side < 0 then math.pi else 0
			local phase = entry.Phase + (joint.Index - 1) * Config.CrayfishLegPhaseStep + sidePhase
			-- 右足は Y軸まわりのプラスで先が前へ、左足は逆。side をかけて、前後の向きをそろえる
			joint.Motor.Transform = CFrame.Angles(0, joint.Side * math.sin(phase) * swing, 0)
		end
	end
end

-- はさみを動かす。歩くと上下にゆれ(左右で逆)、止まると呼吸のようにゆっくりゆれる
local function animateClaws(entry: AnimEntry, t: number)
	local walkBob = math.rad(Config.CrayfishClawBobDeg) * entry.Walk
	local idleBob = math.rad(Config.CrayfishIdleClawDeg) * (1 - entry.Walk)
	local breath = TWO_PI * t / math.max(Config.CrayfishIdleBreathSeconds, MIN_POSITIVE) + entry.Seed
	for _, joint in entry.Claws do
		if joint.Motor.Parent then
			local sidePhase = if joint.Side < 0 then math.pi else 0
			local walkWave = math.sin(entry.Phase * Config.CrayfishClawBobPerCycle + sidePhase)
			local idleWave = math.sin(breath + sidePhase * 0.5)
			joint.Motor.Transform = CFrame.Angles(walkBob * walkWave + idleBob * idleWave, 0, 0)
		end
	end
end

-- ひげを動かす。歩くと後ろ(下向き)にたなびき、止まるとときどきふるえる
local function animateAntennae(entry: AnimEntry, t: number)
	local trail = -math.rad(Config.CrayfishAntennaTrailDeg) * entry.Walk -- X軸のマイナスで、先が下がる
	local wagSize = math.rad(Config.CrayfishAntennaWagDeg) * (1 - entry.Walk)
	-- ふるえる時間帯だけ 0 より大きくなる(Config.CrayfishAntennaWagGapSeconds ごとに少し)
	local gate = math.max(0, math.sin(TWO_PI * t / math.max(Config.CrayfishAntennaWagGapSeconds, MIN_POSITIVE) + entry.Seed))
	local envelope = gate * gate * gate * gate
	local wag = wagSize * envelope * math.sin(TWO_PI * t * Config.CrayfishAntennaWagHz)
	for _, joint in entry.Antennae do
		if joint.Motor.Parent then
			local side = joint.Side
			joint.Motor.Transform = CFrame.Angles(trail, 0, 0) * CFrame.Angles(0, side * wag, 0)
		end
	end
end

-- キャラクター1体を1フレーム分動かす。壊れた状態なら、何もしない
local function updateEntry(entry: AnimEntry, t: number, dt: number)
	if entry.Character:GetAttribute(HIDDEN_ATTRIBUTE) == true then
		return -- 潜っているときは、姿勢を保つ(更新しない)
	end
	local root = getRoot(entry)
	if not root then
		return
	end
	if entry.Dirty then
		rebuildJoints(entry)
	end
	advance(entry, horizontalSpeed(root), dt)
	animateLegs(entry)
	animateClaws(entry, t)
	animateAntennae(entry, t)
end

-- 毎フレーム呼ばれる
local function onRenderStepped(dt: number)
	local clamped = math.min(dt, MAX_DT)
	local t = os.clock()
	for visual, entry in entries do
		if not visual.Parent or not entry.Character.Parent then
			removeEntry(visual) -- 表の書き換え中の削除は、Luau では許される
		else
			updateEntry(entry, t, clamped)
		end
	end
end

function CrayfishAnimator.Start()
	if renderConnection then
		return -- 二重に起動しない
	end
	-- いまある CrayfishVisual を、最初に1回だけ探す
	for _, descendant in Workspace:GetDescendants() do
		registerVisual(descendant)
	end
	-- あとから生まれる(生まれ直し、他のプレイヤー)分を拾う
	workspaceConnection = Workspace.DescendantAdded:Connect(registerVisual)
	renderConnection = RunService.RenderStepped:Connect(onRenderStepped)
end

return CrayfishAnimator
