--!strict
-- 巨人(農家さん)の「迫ってくる実感」をつくる(仕様書 014 の 3)。クライアント(自分の端末)だけで動かす。
-- やること:
--   1. 巨人の歩き: 農家さんの関節(Motor6D)の Transform を、毎フレーム動かす(ザリガニの足の動き(仕様書 010)と同じ方式)
--   2. 足音: 足が地面につくたびに、カメラ(Humanoid.CameraOffset)を上下にはねさせ、3Dの足音を鳴らす
--   3. 気づいた音: 農家さんが Notice になった瞬間に、3Dで1回鳴らす
--   4. 近づく緊張: Notice・Chase の農家さんが近いほど、画面を赤く・暗くする(専用の ColorCorrectionEffect)
--   5. 心臓の音: 緊張しているあいだ、くり返し鳴らす
-- Transform や CameraOffset は、この端末だけに効く。サーバーには届かない。新しい通信(RemoteEvent)も足さない。
-- 音のID(Config.SoundIds)が空なら、Sound を作らない・鳴らさない(エラーも警告も出ない)。
--
-- 関節の向き(R15 の関節は、体の向きと同じ座標系): X=右、Y=上、前が -Z
--   足・腕: X軸まわりに回す。プラスの角度で、先(足先・手先)が前(-Z)へ出る
--   膝:     X軸まわりのマイナスで、足先が後ろへ曲がる(膝を曲げる)
--   首:     Y軸まわりに回す → 左右に向く
--   腰(Waist): 位置(Y)を動かして体を上下させ、X軸まわりの小さな回転で息づかいを出す

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config") :: ModuleScript)
local SoundUtil = require(Shared:WaitForChild("SoundUtil") :: ModuleScript)

local EnemyPresenceController = {}

local ENEMIES_FOLDER_NAME = "Enemies" -- EnemyService が作るフォルダの名前
local STATE_ATTRIBUTE = "EnemyState" -- 農家さんだけにつく Attribute(稲刈り機にはない)
local STATE_NOTICE = "Notice"
local STATE_CHASE = "Chase"
local STATE_SEARCH = "Search"
local THREAT_EFFECT_NAME = "FieldThreatColorCorrection" -- LightingController の "FieldColorCorrection" とは別のもの
local SEPARATE_EFFECT_ATTRIBUTE = "SeparateEffect" -- LightingController が「同じ種類の最初の1つ」として拾わないための目印
local HEARTBEAT_SOUND_NAME = "Sound_Heartbeat"
local TWO_PI = 2 * math.pi
local HALF_PI = math.pi / 2
local MAX_DT = 0.1 -- 1フレームの時間の上限(重いときに、急に飛ばないように)
local MIN_POSITIVE = 0.001 -- 割り算の下の数がこれより小さくならないようにする下限(Config が 0 でも、0 で割らない)
local SHAKE_EPSILON = 0.0005 -- カメラのはねが、これより小さければ 0 にする(スタッド)
local WHITE = Color3.new(1, 1, 1)

-- 農家さん1体の記録
type Entry = {
	Model: Model,
	Root: BasePart?, -- HumanoidRootPart(見つかったら覚える)
	Dirty: boolean, -- 関節を探し直す必要があるか
	LeftHip: Motor6D?,
	RightHip: Motor6D?,
	LeftKnee: Motor6D?,
	RightKnee: Motor6D?,
	LeftShoulder: Motor6D?,
	RightShoulder: Motor6D?,
	Waist: Motor6D?,
	Neck: Motor6D?,
	Walk: number, -- 歩きの度合い(0 = 止まっている、1 = 歩いている。なめらかに変わる)
	NoticeAmount: number, -- 気づいて腕を上げている度合い(0〜1)
	SearchAmount: number, -- 首をふっている度合い(0〜1)
	PrevPosition: Vector3?, -- 前のフレームの位置(位置の差から速さを求める。まだ見ていなければ nil)
	Phase: number, -- 歩きの位相(ラジアン)。歩いた距離に比例して進む(止まると進まない)
	LastStepIndex: number, -- 最後に足音を起こした番号(足音は、位相が π ごとに1回)
	PrevState: string?, -- 前のフレームの EnemyState(Notice に変わった瞬間を見つけるため)
	StepSound: Sound?,
	NoticedSound: Sound?,
	Connections: { RBXScriptConnection },
}

local entries: { [Instance]: Entry } = {} -- 農家さん(になりうるモデル) → 記録
local folderConnections: { RBXScriptConnection } = {} -- Enemies フォルダを見るつなぎ
local playerConnections: { RBXScriptConnection } = {} -- 自分のキャラクターの生まれ直しを見るつなぎ
local workspaceConnection: RBXScriptConnection? = nil -- Enemies フォルダが後から作られるのを待つつなぎ
local renderConnection: RBXScriptConnection? = nil

-- カメラの揺れ
local shake = 0 -- いまのはね(スタッド)
local appliedShake = 0 -- Humanoid.CameraOffset に足してある分(戻すときに引く)
local shakeHumanoid: Humanoid? = nil -- はねを足してある Humanoid

-- 緊張
local threat = 0 -- いまの緊張の強さ(0〜1。なめらかに目標へ近づく)
local appliedThreat = 0 -- 最後に画面へ反映した強さ
local threatEffect: ColorCorrectionEffect? = nil
local threatEffectCreated = false -- 自分で作ったか(Stop で消す)

-- 心臓の音
local heartbeatSound: Sound? = nil
local heartbeatPlaying = false

-- ===== 小さな道具 =====

local function lerpNumber(a: number, b: number, t: number): number
	return a + (b - a) * t
end

-- 水平方向の速さ(スタッド/秒)。上下の動きは含めない。
-- サーバーが動かしている NPC は、クライアントでは AssemblyLinearVelocity が 0 に見えることがある。
-- そのため、「前のフレームとの位置の差 ÷ dt」(水平成分)も求めて、大きいほうを使う。
-- 位置の差が FarmerMaxPlausibleSpeed を超えたときは、テレポート(やり直しで出現位置に戻る、など)とみなして、位置の差のほうは使わない
local function horizontalSpeed(entry: Entry, root: BasePart, dt: number): number
	local velocity = root.AssemblyLinearVelocity
	local velocitySpeed = math.sqrt(velocity.X * velocity.X + velocity.Z * velocity.Z)

	local position = root.Position
	local previous = entry.PrevPosition
	entry.PrevPosition = position
	if previous == nil then
		return velocitySpeed
	end
	local dx = position.X - previous.X
	local dz = position.Z - previous.Z
	local movedSpeed = math.sqrt(dx * dx + dz * dz) / math.max(dt, MIN_POSITIVE)
	if movedSpeed > Config.FarmerMaxPlausibleSpeed then
		return velocitySpeed -- テレポートなどで、ありえない大きさ。位置の差は無視する
	end
	return math.max(velocitySpeed, movedSpeed)
end

-- 自分のキャラクターの位置。なければ nil
local function getLocalPosition(): Vector3?
	local player = Players.LocalPlayer
	local character = player.Character
	if not character then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root.Position
	end
	return nil
end

-- 近さの強さ(0〜1)。横方向の距離で測る。0 = maxDistance 以上はなれている、1 = 真横
local function proximity(root: BasePart, localPosition: Vector3?, maxDistance: number): number
	if localPosition == nil then
		return 0
	end
	local dx = root.Position.X - localPosition.X
	local dz = root.Position.Z - localPosition.Z
	local distance = math.sqrt(dx * dx + dz * dz)
	return math.clamp(1 - distance / math.max(maxDistance, MIN_POSITIVE), 0, 1)
end

-- ===== 音 =====

-- 農家さんの HumanoidRootPart の下に、3Dの Sound を作る(IDが有効なときだけ)。すでにあれば、それを返す
local function ensureSound3D(root: BasePart, soundName: string, existing: Sound?): Sound?
	if existing ~= nil and existing.Parent ~= nil then
		return existing
	end
	local soundId = SoundUtil.GetId(soundName)
	if soundId == nil then
		return nil
	end
	local sound = Instance.new("Sound")
	sound.Name = "Sound_" .. soundName
	sound.SoundId = soundId
	sound.Volume = SoundUtil.GetVolume(soundName)
	sound.RollOffMinDistance = Config.FarmerStepRollOffMin
	sound.RollOffMaxDistance = Config.FarmerStepRollOffMax
	sound.Parent = root -- Part の下に置くと、その位置から聞こえる(3D)
	return sound
end

local function playSound(sound: Sound?)
	if sound ~= nil and sound.Parent ~= nil then
		sound.TimePosition = 0
		sound:Play()
	end
end

-- ===== 関節 =====

local function findJoint(model: Model, name: string): Motor6D?
	local found = model:FindFirstChild(name, true)
	if found and found:IsA("Motor6D") then
		return found
	end
	return nil
end

-- 関節を探し直す。見つからないもの(簡易モデルなど)は nil のまま(あとで動かすときに飛ばす)
local function rebuildJoints(entry: Entry)
	local model = entry.Model
	entry.LeftHip = findJoint(model, "LeftHip")
	entry.RightHip = findJoint(model, "RightHip")
	entry.LeftKnee = findJoint(model, "LeftKnee")
	entry.RightKnee = findJoint(model, "RightKnee")
	entry.LeftShoulder = findJoint(model, "LeftShoulder")
	entry.RightShoulder = findJoint(model, "RightShoulder")
	entry.Waist = findJoint(model, "Waist")
	entry.Neck = findJoint(model, "Neck")
	entry.Dirty = false
end

-- 関節を、元の姿勢に戻す(Stop のとき)
local function resetJoint(motor: Motor6D?)
	if motor ~= nil and motor.Parent ~= nil then
		motor.Transform = CFrame.new()
	end
end

local function resetJoints(entry: Entry)
	resetJoint(entry.LeftHip)
	resetJoint(entry.RightHip)
	resetJoint(entry.LeftKnee)
	resetJoint(entry.RightKnee)
	resetJoint(entry.LeftShoulder)
	resetJoint(entry.RightShoulder)
	resetJoint(entry.Waist)
	resetJoint(entry.Neck)
end

-- 関節1つに、Transform を入れる(関節がなければ飛ばす)
local function setTransform(motor: Motor6D?, transform: CFrame)
	if motor ~= nil and motor.Parent ~= nil then
		motor.Transform = transform
	end
end

-- ===== 記録の出し入れ =====

-- 記録を消す(つないだものも切り、作った Sound も消して、メモリを残さない)
local function removeEntry(instance: Instance)
	local entry = entries[instance]
	if not entry then
		return
	end
	for _, connection in entry.Connections do
		connection:Disconnect()
	end
	table.clear(entry.Connections)
	if entry.StepSound then
		entry.StepSound:Destroy()
		entry.StepSound = nil
	end
	if entry.NoticedSound then
		entry.NoticedSound:Destroy()
		entry.NoticedSound = nil
	end
	entries[instance] = nil
end

-- Enemies の子を記録に入れる。Model 以外は無視する。
-- 農家さんかどうか(EnemyState を持つか)は、毎フレーム見る(Attribute が少し遅れて届いてもよいように)
local function registerModel(instance: Instance)
	if entries[instance] or not instance:IsA("Model") then
		return
	end
	local entry: Entry = {
		Model = instance,
		Root = nil,
		Dirty = true,
		LeftHip = nil,
		RightHip = nil,
		LeftKnee = nil,
		RightKnee = nil,
		LeftShoulder = nil,
		RightShoulder = nil,
		Waist = nil,
		Neck = nil,
		Walk = 0,
		NoticeAmount = 0,
		SearchAmount = 0,
		PrevPosition = nil,
		Phase = 0,
		LastStepIndex = -1, -- 位相 0 では、まだ最初の足音の前(最初の足音は位相 π/2)
		PrevState = nil,
		StepSound = nil,
		NoticedSound = nil,
		Connections = {},
	}
	-- 関節があとから足された・消されたら、探し直す
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
	-- Workspace から外れたり消えたりしたら、記録を消す
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

local function getRoot(entry: Entry): BasePart?
	local root = entry.Root
	if root and root.Parent then
		return root
	end
	local found = entry.Model:FindFirstChild("HumanoidRootPart")
	if found and found:IsA("BasePart") then
		entry.Root = found
		return found
	end
	entry.Root = nil
	return nil
end

-- ===== 巨人の歩き =====

-- 切り替えの度合いを、目標へなめらかに近づける(フレームの長さによらず、同じ速さ)
local function approach(current: number, target: number, dt: number): number
	local alpha = 1 - math.exp(-Config.FarmerAnimBlendPerSecond * dt)
	return current + (target - current) * alpha
end

-- 歩きの度合いと位相を進める。歩いた距離で位相を進めるので、速いほど速く動く。
-- 止まっているとき(MoveMinSpeed 以下)は、位相を進めない。
-- 足が地面につく瞬間(位相が π/2 + π の整数倍になったとき)に true を返す
local function advance(entry: Entry, speed: number, dt: number): boolean
	local moving = speed > Config.FarmerMoveMinSpeed
	entry.Walk = approach(entry.Walk, if moving then 1 else 0, dt)
	if not moving then
		return false
	end
	-- 歩いた距離(速さ × dt) ÷ 1歩の距離 × π。位相が π 進むごとに、足が1回地面につく(足の1往復 = 2歩)
	entry.Phase += speed * dt / math.max(Config.FarmerStrideStuds, MIN_POSITIVE) * math.pi
	local stepIndex = math.floor((entry.Phase - HALF_PI) / math.pi)
	if stepIndex > entry.LastStepIndex then
		entry.LastStepIndex = stepIndex
		return true
	end
	return false
end

-- 足・膝・腕・腰・首を動かす
local function animate(entry: Entry, state: string, t: number, dt: number)
	entry.NoticeAmount = approach(entry.NoticeAmount, if state == STATE_NOTICE then 1 else 0, dt)
	entry.SearchAmount = approach(entry.SearchAmount, if state == STATE_SEARCH then 1 else 0, dt)
	local walk = entry.Walk
	local phase = entry.Phase
	local leftPhase = phase + math.pi -- 左右の足は逆位相
	local rightPhase = phase

	-- 足: X軸のプラスで、足先が前へ
	local legSwing = math.rad(Config.FarmerLegSwingDeg) * walk
	setTransform(entry.LeftHip, CFrame.Angles(legSwing * math.sin(leftPhase), 0, 0))
	setTransform(entry.RightHip, CFrame.Angles(legSwing * math.sin(rightPhase), 0, 0))

	-- 膝: 足が後ろから前へ出るとき(sin が増えているとき = cos がプラス)だけ、X軸のマイナスで曲げる
	local kneeBend = math.rad(Config.FarmerKneeBendDeg) * walk
	setTransform(entry.LeftKnee, CFrame.Angles(-kneeBend * math.max(0, math.cos(leftPhase)), 0, 0))
	setTransform(entry.RightKnee, CFrame.Angles(-kneeBend * math.max(0, math.cos(rightPhase)), 0, 0))

	-- 腕: 同じ側の足と逆向きにふる。気づいたときは、両腕を前へ持ち上げる
	local armSwing = math.rad(Config.FarmerArmSwingDeg) * walk
	local armRaise = math.rad(Config.FarmerNoticeArmRaiseDeg) * entry.NoticeAmount
	setTransform(entry.LeftShoulder, CFrame.Angles(armSwing * math.sin(leftPhase + math.pi) + armRaise, 0, 0))
	setTransform(entry.RightShoulder, CFrame.Angles(armSwing * math.sin(rightPhase + math.pi) + armRaise, 0, 0))

	-- 腰: 歩くと上下する(足が地面につく瞬間がいちばん低く、足がすれちがうときがいちばん高い。周波数は足の2倍)。
	--     止まっているときは、ゆっくり前後にゆれる(息づかい)
	local bob = Config.FarmerBobStuds * walk * (0.5 + 0.5 * math.cos(2 * phase))
	local breathAngle = math.rad(Config.FarmerIdleBreathDeg)
		* (1 - walk)
		* math.sin(TWO_PI * t / math.max(Config.FarmerIdleBreathSeconds, MIN_POSITIVE))
	setTransform(entry.Waist, CFrame.new(0, bob, 0) * CFrame.Angles(breathAngle, 0, 0))

	-- 首: 探すとき、Y軸まわりに左右へふる(きょろきょろ)
	local neckAngle = math.rad(Config.FarmerSearchNeckSwingDeg) * entry.SearchAmount * math.sin(TWO_PI * t * Config.FarmerSearchNeckHz)
	setTransform(entry.Neck, CFrame.Angles(0, neckAngle, 0))
end

-- 農家さん1体を1フレーム分動かす。
-- 戻り値: (緊張の強さ 0〜1, カメラのはねの高さ)。農家さんでない・壊れている・足音の瞬間でないなら 0
local function updateEntry(entry: Entry, t: number, dt: number, localPosition: Vector3?): (number, number)
	local state = entry.Model:GetAttribute(STATE_ATTRIBUTE)
	if type(state) ~= "string" then
		return 0, 0 -- 稲刈り機など(EnemyState を持たないもの)は対象外
	end
	local root = getRoot(entry)
	if not root then
		return 0, 0
	end
	if entry.Dirty then
		rebuildJoints(entry)
	end

	-- 気づいた瞬間(最初に見たときの状態では鳴らさない)
	if entry.PrevState ~= nil and entry.PrevState ~= STATE_NOTICE and state == STATE_NOTICE then
		entry.NoticedSound = ensureSound3D(root, "FarmerNoticed", entry.NoticedSound)
		playSound(entry.NoticedSound)
	end
	entry.PrevState = state

	local footfall = advance(entry, horizontalSpeed(entry, root, dt), dt)
	animate(entry, state, t, dt)

	local kick = 0
	if footfall then
		kick = Config.FarmerShakeMaxOffset * proximity(root, localPosition, Config.FarmerShakeMaxDistance)
		entry.StepSound = ensureSound3D(root, "FarmerStep", entry.StepSound)
		playSound(entry.StepSound)
	end
	local entryThreat = 0
	if state == STATE_NOTICE or state == STATE_CHASE then
		entryThreat = proximity(root, localPosition, Config.FarmerThreatMaxDistance)
	end
	return entryThreat, kick
end

-- ===== カメラの揺れ =====

-- はねを足してある Humanoid から、足した分を引く(古い Humanoid を、いつまでも掴まない)
local function releaseShake()
	local humanoid = shakeHumanoid
	if humanoid ~= nil and appliedShake ~= 0 and humanoid.Parent ~= nil then
		humanoid.CameraOffset -= Vector3.new(0, appliedShake, 0)
	end
	shakeHumanoid = nil
	appliedShake = 0
end

local function getLocalHumanoid(): Humanoid?
	local current = shakeHumanoid
	if current ~= nil and current.Parent ~= nil then
		return current
	end
	local character = Players.LocalPlayer.Character
	if not character then
		return nil
	end
	return character:FindFirstChildOfClass("Humanoid")
end

-- はねを、指数的に 0 へ戻す。足音の瞬間(kick > 0)は、大きいほうを取る(重なっても最大値を超えない)。
-- CameraOffset は「足した分だけ引く」やり方で書くので、ほかの機能が使っても干渉しない
local function updateShake(kick: number, dt: number)
	shake = math.max(shake * math.exp(-dt / math.max(Config.FarmerShakeDecaySeconds, MIN_POSITIVE)), kick)
	if shake < SHAKE_EPSILON then
		shake = 0
	end
	local humanoid = getLocalHumanoid()
	if humanoid ~= shakeHumanoid then
		releaseShake() -- 別の Humanoid に変わった(生まれ直し)。古いほうの分を戻す
		shakeHumanoid = humanoid
	end
	if humanoid == nil or shake == appliedShake then
		return
	end
	humanoid.CameraOffset += Vector3.new(0, shake - appliedShake, 0)
	appliedShake = shake
end

-- ===== 近づく緊張 =====

-- Lighting の下から、緊張用の色補正を探す(名前だけで探す。なければ作る)
local function ensureThreatEffect(): ColorCorrectionEffect
	local existing = threatEffect
	if existing ~= nil and existing.Parent ~= nil then
		return existing
	end
	local byName = Lighting:FindFirstChild(THREAT_EFFECT_NAME)
	if byName and byName:IsA("ColorCorrectionEffect") then
		threatEffect = byName
		threatEffectCreated = false
		return byName
	end
	local made = Instance.new("ColorCorrectionEffect")
	made.Name = THREAT_EFFECT_NAME
	made:SetAttribute(SEPARATE_EFFECT_ATTRIBUTE, true)
	made.Parent = Lighting
	threatEffect = made
	threatEffectCreated = true
	return made
end

-- 緊張の強さを、画面の色に反映する。0 のときは「効果なし」(白、0、0)
local function applyThreat(amount: number)
	local effect = ensureThreatEffect()
	effect.TintColor = WHITE:Lerp(Config.FarmerThreatTint, amount)
	effect.Saturation = lerpNumber(0, Config.FarmerThreatSaturation, amount)
	effect.Brightness = lerpNumber(0, Config.FarmerThreatBrightness, amount)
	appliedThreat = amount
end

-- 目標の強さへ、なめらかに近づける。値が変わったときだけ画面へ反映する
local function updateThreat(target: number, dt: number)
	local alpha = 1 - math.exp(-Config.FarmerThreatSmoothRate * dt)
	threat += (target - threat) * alpha
	if target == 0 and threat < Config.FarmerThreatUpdateEpsilon then
		threat = 0
	end
	if math.abs(threat - appliedThreat) >= Config.FarmerThreatUpdateEpsilon or (threat == 0 and appliedThreat ~= 0) then
		applyThreat(threat)
	end
end

-- ===== 心臓の音 =====

-- 緊張の強さが一定を超えたら鳴らし、以下なら止める。音量は、緊張が強いほど大きい
local function updateHeartbeat()
	local sound = heartbeatSound
	if sound == nil or sound.Parent == nil then
		return
	end
	if threat > Config.FarmerHeartbeatOnThreshold then
		local ratio = math.clamp(threat, Config.FarmerHeartbeatMinVolumeRatio, 1)
		local volume = SoundUtil.GetVolume("Heartbeat") * ratio
		if math.abs(sound.Volume - volume) > Config.FarmerHeartbeatVolumeEpsilon then
			sound.Volume = volume
		end
		if not heartbeatPlaying then
			heartbeatPlaying = true
			sound:Play()
		end
	elseif heartbeatPlaying then
		heartbeatPlaying = false
		sound:Stop()
	end
end

-- IDが有効なら、心臓の音の Sound を SoundService の下に1つ作る
local function createHeartbeatSound()
	local soundId = SoundUtil.GetId("Heartbeat")
	if soundId == nil then
		return
	end
	local sound = Instance.new("Sound")
	sound.Name = HEARTBEAT_SOUND_NAME
	sound.SoundId = soundId
	sound.Volume = 0
	sound.Looped = true
	sound.Parent = SoundService
	heartbeatSound = sound
end

-- ===== 毎フレーム =====

local function onRenderStepped(dt: number)
	local clamped = math.min(dt, MAX_DT)
	local t = os.clock()
	local localPosition = getLocalPosition()
	local targetThreat = 0
	local kick = 0
	for instance, entry in entries do
		if not instance.Parent then
			removeEntry(instance) -- 表の書き換え中の削除は、Luau では許される
		else
			local entryThreat, entryKick = updateEntry(entry, t, clamped, localPosition)
			targetThreat = math.max(targetThreat, entryThreat)
			kick = math.max(kick, entryKick)
		end
	end
	updateShake(kick, clamped)
	updateThreat(targetThreat, clamped)
	updateHeartbeat()
end

-- ===== 対象の見つけ方 =====

local function disconnectAll(list: { RBXScriptConnection })
	for _, connection in list do
		connection:Disconnect()
	end
	table.clear(list)
end

-- Enemies フォルダの子を見はじめる(すでにいる分と、あとから増える・消える分)
local function attachFolder(folder: Instance)
	disconnectAll(folderConnections)
	for _, child in folder:GetChildren() do
		registerModel(child)
	end
	table.insert(folderConnections, folder.ChildAdded:Connect(registerModel))
	table.insert(folderConnections, folder.ChildRemoved:Connect(removeEntry))
end

-- 自分のキャラクターが生まれ直したら、揺れの状態をリセットする
local function onLocalCharacterChanged()
	releaseShake()
	shake = 0
end

function EnemyPresenceController.Start()
	if renderConnection then
		return -- 二重に起動しない
	end
	-- Enemies フォルダは、最初の農家さんが出るときにサーバーが作る。いまあれば使い、なければ現れるのを待つ
	-- (待つ時間は無制限だが、イベントで待つだけなので、ほかの部品は止まらない)
	local folder = Workspace:FindFirstChild(ENEMIES_FOLDER_NAME)
	if folder then
		attachFolder(folder)
	end
	workspaceConnection = Workspace.ChildAdded:Connect(function(child: Instance)
		if child.Name == ENEMIES_FOLDER_NAME then
			attachFolder(child)
		end
	end)

	local player = Players.LocalPlayer
	table.insert(playerConnections, player.CharacterAdded:Connect(onLocalCharacterChanged))
	table.insert(playerConnections, player.CharacterRemoving:Connect(onLocalCharacterChanged))

	createHeartbeatSound()
	renderConnection = RunService.RenderStepped:Connect(onRenderStepped)
end

-- 止めて、作ったものを片付ける(このゲームでは普段は呼ばない。LightingController の Stop と同じ考え方)
function EnemyPresenceController.Stop()
	if renderConnection then
		renderConnection:Disconnect()
		renderConnection = nil
	end
	if workspaceConnection then
		workspaceConnection:Disconnect()
		workspaceConnection = nil
	end
	disconnectAll(folderConnections)
	disconnectAll(playerConnections)

	for instance, entry in entries do
		resetJoints(entry)
		removeEntry(instance)
	end
	table.clear(entries)

	releaseShake()
	shake = 0

	local effect = threatEffect
	if effect ~= nil then
		if threatEffectCreated then
			effect:Destroy() -- 自分で作ったものだけ消す
		else
			effect.TintColor = WHITE
			effect.Saturation = 0
			effect.Brightness = 0
		end
	end
	threatEffect = nil
	threatEffectCreated = false
	threat = 0
	appliedThreat = 0

	if heartbeatSound ~= nil then
		heartbeatSound:Destroy()
		heartbeatSound = nil
	end
	heartbeatPlaying = false
end

return EnemyPresenceController
