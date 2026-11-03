--!strict
-- AIのザリガニ(農家さんモードの「つかまえる相手」)。仕様書 016 の 4。
-- 農家さんのラウンドが始まると、難易度の数(PreyCount)だけ出して、サーバーが動かす。
-- プレイヤー(巨人の農家さん)がつかまえる判定も、ここで行う(サーバーが正)。
--
-- 見た目:人型(Humanoid)の土台を CreateHumanoidModelFromDescription で作り、CrayfishModel でザリガニの見た目をつけて、人型は隠す。
--   土台は最初に1つだけ作って「見本」にし、あとは Clone(複製)で増やす(人型の作成は待ちが入るので、数ひきぶん待たないため)。
-- 動き(状態):
--   Wander(うろうろ):田んぼの中のランダムな点へ歩く。ときどき立ち止まる。
--   Flee(にげる):農家さんが気づく距離(PreySightDistance × 難易度)以内に来たら、遠ざかる向きの点へ走る。壁ぎわでは壁にそって逃げる。
--   Dive(潜る):近づかれて、確率で、PreyDiveSeconds のあいだ潜る(動けない・半透明・Attribute Hidden)。
--   Jet(ジェット):もっと近づかれて、確率で、遠ざかる向きに噴射(Attribute Jetting。クライアントの CrayfishAnimator が尻尾と粒子を動かす)。
--   状態を変える前に、PreyReactionSeconds のランダムな遅れを入れる(完璧に逃げない)。出現から PreyStartGraceSeconds は逃げない。
-- 判断のループは1つ(EnemyTickSeconds ごと)。やり直し・メニュー戻りで Clear したあと、古いループは、番号(loopToken)が合わなくなって終わる。
-- 出している途中で消された場合(待ちの間に Clear された)は、プレイヤーごとのまとまり(Session)が別物になるので、それで見分ける。
-- 壊れたAIは、「つかまえた」扱いにしない。新しい個体を出し直す(出し直せなければ、数から外す)。
--   のこりが 0 になったとき、つかまえた数(CaughtCount)が 1 以上ならクリア、0 なら「にげられた…」(Caught)で終える。
-- AIザリガニどうしは、衝突グループ "Prey" で、ぶつからない(床とは、ぶつかる)。
-- 潜る・ジェットの終わりは、タイマーではなく、判断のループが時刻(os.clock)を見て決める(古いタイマーが残らない)。
--
-- 依存の向き:この部品は RoundService などを読み込む。RoundService は、この部品を読み込まない(循環 require を防ぐ)。
--   RoundService の OnRestart・OnRoundStart・OnRoundEnd に、関数を登録してもらう。

local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local WarnOnce = require(script.Parent.Enemy.WarnOnce)
local FarmerPlayer = require(script.Parent.FarmerPlayer)
local FieldService = require(script.Parent.FieldService)
local RoundService = require(script.Parent.RoundService)
local ScoreService = require(script.Parent.ScoreService)
local SetupService = require(script.Parent.SetupService)

-- 見た目の部品は ServerStorage/Modules にある(Rojo の対応は default.project.json)
local modulesFolder = ServerStorage:WaitForChild("Modules", 10)
assert(modulesFolder, "[PreyService] ServerStorage/Modules が見つかりません")
local crayfishModelScript = modulesFolder:WaitForChild("CrayfishModel", 10)
assert(crayfishModelScript, "[PreyService] CrayfishModel が見つかりません")
local CrayfishModel = require(crayfishModelScript :: ModuleScript)
local farmerModelScript = modulesFolder:WaitForChild("FarmerModel", 10)
assert(farmerModelScript, "[PreyService] FarmerModel が見つかりません")
local FarmerModel = require(farmerModelScript :: ModuleScript)

local FOLDER_NAME = "Prey" -- AIザリガニを入れるフォルダ(Workspace の直下)
local VISUAL_FOLDER_NAME = "CrayfishVisual" -- CrayfishModel と同じ名前
local PREY_REMAINING_ATTRIBUTE = "PreyRemaining" -- のこりのひき数(Player の Attribute。クライアントが読む)
local MIN_SECONDS = 0.001 -- 待ち時間の下限(秒)。Config が 0 でも、busy loop(待ちなしの繰り返し)にならないように
local TINY = 0.01 -- これより短いベクトルは「向きなし」とみなす
local MIN_COUNT = 1 -- 出す数の下限
local COLLISION_GROUP = "Prey" -- AIザリガニどうしが、ぶつからないようにするための、衝突グループの名前

-- AIの状態の名前
type PreyMode = "Wander" | "Flee" | "Dive" | "Jet"

-- AIザリガニ1ぴきの状態
type Prey = {
	Id: number,
	Model: Model,
	Humanoid: Humanoid,
	Root: BasePart,
	Random: Random, -- このザリガニだけの乱数
	BaseSpeed: number, -- 歩く速さ(PreyWalkSpeed × 難易度)
	Awareness: number, -- 農家さんに気づく距離(PreySightDistance × 難易度)
	Mode: PreyMode,
	ModeUntil: number, -- Dive・Jet が終わる時刻(os.clock)
	GraceUntil: number, -- この時刻まで、逃げない(出現直後の猶予)
	WanderTarget: Vector3?, -- うろうろの行き先
	WanderTargetUntil: number, -- この時刻までに着かなければ、行き先を選び直す
	PauseUntil: number, -- この時刻まで、立ち止まっている
	PendingMode: PreyMode?, -- 反応の遅れの間に、待たせている状態
	ReactAt: number, -- PendingMode に変える時刻
	DiveReadyAt: number, -- この時刻から、潜れる
	JetReadyAt: number, -- この時刻から、ジェットできる
	NextDiveRollAt: number, -- この時刻まで、潜る「くじ」を引かない
	NextJetRollAt: number, -- この時刻まで、ジェットの「くじ」を引かない
	JetDirection: Vector3, -- ジェットの向き(水平、長さ1)
	OriginalTransparency: { [BasePart]: number }, -- 潜る前の透明度(浮上で戻す)
}

-- プレイヤー1人ぶんの、AIザリガニのまとまり(Player をキーにした表で持つ)
type Session = {
	Player: Player,
	Preys: { [number]: Prey }, -- 番号 → AIザリガニ(つかまえたら表から消す)
	Remaining: number, -- のこりのひき数(つかまえた・出し直せなかったぶんは、減る)
	CaughtCount: number, -- つかまえた数(壊れて数から外れたぶんは、入れない。全滅したとき、クリアか「にげられた」かを分ける)
}

local PreyService = {}

local sessions: { [Player]: Session } = {}
local nextId = 0
local loopToken = 0 -- 判断のループの番号。新しいループを始めるたびに増やし、古いループは自分で終わる
local loopRunning = false -- いま判断のループが動いているか
local template: Model? = nil -- 見本(ザリガニの見た目をつけた人型)。Clone で増やす
local templateBuilding = false -- 見本を作っている最中か
local folder: Folder? = nil
local started = false
local collisionGroupReady = false -- 衝突グループ "Prey" を、使える状態にできたか

-- ===== 小さな道具 =====

-- Prey フォルダ(なければ作る)
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

-- このザリガニだけの乱数。Config.EnemyRandomSeed が 0 以外なら、固定(デバッグ用)
local function newRandom(id: number): Random
	local seed = Config.EnemyRandomSeed
	if seed ~= 0 then
		return Random.new(seed + id)
	end
	return Random.new()
end

-- 横方向(XZ)の距離。高さの違いは無視する
local function flatDistance(a: Vector3, b: Vector3): number
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

-- 倍率として使える数字か(数字で、NaN・無限大ではなく、0より大きい)。使えなければ 1
local function getMultiplier(params: { [string]: number }, name: string): number
	local value = params[name]
	if type(value) ~= "number" or value ~= value or value <= 0 or value == math.huge then
		return 1
	end
	return value
end

-- 出す数。難易度の PreyCount を、1 〜 PreyCountMax に収める(使えない値なら 1)
local function getPreyCount(params: { [string]: number }): number
	local value = params.PreyCount
	if type(value) ~= "number" or value ~= value then
		return MIN_COUNT
	end
	return math.clamp(math.floor(value), MIN_COUNT, math.max(Config.PreyCountMax, MIN_COUNT))
end

-- min 〜 max のランダムな秒数(0.001 秒より小さくならない。min が max より大きくても、入れ替えて使う)
local function randomSeconds(random: Random, minSeconds: number, maxSeconds: number): number
	local low = math.min(minSeconds, maxSeconds)
	local high = math.max(minSeconds, maxSeconds)
	if high <= low then
		return math.max(low, MIN_SECONDS)
	end
	return math.max(random:NextNumber(low, high), MIN_SECONDS)
end

local function signOf(value: number): number
	return if value >= 0 then 1 else -1
end

-- 田んぼの中心(横位置)
local function getFieldCenter(): Vector3
	return FieldService.GetFieldBounds().Center
end

-- 歩き回ってよい範囲の、中心からの半分の長さ(壁から PreyWallMargin だけ内側)
local function getPlayableHalf(): number
	return math.max(Config.FieldSize / 2 - Config.PreyWallMargin, 0)
end

-- ===== 見た目(見本づくり) =====

-- 人型(R15)の作成を、失敗したら待ってやり直しながら試す。全部失敗したら nil(FarmerModel と同じ作り方)
local function tryCreateHumanoid(): Model?
	for attempt = 1, Config.FarmerCreateMaxAttempts do
		local description = Instance.new("HumanoidDescription")
		local ok, result = pcall(function()
			return Players:CreateHumanoidModelFromDescription(description, Enum.HumanoidRigType.R15)
		end)
		description:Destroy()
		if ok and typeof(result) == "Instance" and result:IsA("Model") then
			return result
		end
		warn(`[PreyService] 人型の作成に失敗しました({attempt}/{Config.FarmerCreateMaxAttempts}回目): {result}`)
		if attempt < Config.FarmerCreateMaxAttempts then
			task.wait(Config.FarmerCreateRetryWaitSeconds)
		end
	end
	return nil
end

-- 人型を作れなかったときの代わり:HumanoidRootPart と Humanoid だけの簡易モデル(ザリガニの見た目をつければ、見た目は同じ)
local function createFallback(): Model
	local model = Instance.new("Model")
	model.Name = "PreyTemplate"
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Config.PreyFallbackRootSize
	root.Transparency = 1 -- 見えない(ザリガニの見た目だけが見える)
	root.CFrame = CFrame.new(0, 0, 0)
	root.Parent = model
	model.PrimaryPart = root
	local humanoid = Instance.new("Humanoid")
	humanoid.HipHeight = Config.PreyFallbackHipHeight
	humanoid.RequiresNeck = false -- 簡易モデルには首の関節がないので、首が無くても倒れないようにする
	humanoid.Parent = model
	return model
end

-- 衝突グループ "Prey" を作って、"Prey" どうしは、ぶつからないようにする(1回だけ)。
-- 床(Default グループ)とは、ぶつかったまま:AIが、床をすり抜けて落ちないように。
-- すでに登録されていると RegisterCollisionGroup はエラーになるので、pcall で包む。使える状態になったら true
local function ensureCollisionGroup(): boolean
	if collisionGroupReady then
		return true
	end
	pcall(function()
		PhysicsService:RegisterCollisionGroup(COLLISION_GROUP) -- すでに登録済みなら、エラー(無視してよい)
	end)
	local ok, err = pcall(function()
		PhysicsService:CollisionGroupSetCollidable(COLLISION_GROUP, COLLISION_GROUP, false)
	end)
	if not ok then
		WarnOnce.Warn("PreyCollisionGroup", `[PreyService] 衝突グループを設定できませんでした: {err}`)
		return false
	end
	collisionGroupReady = true
	return true
end

-- すべての部品を、衝突グループ "Prey" に入れる(AIザリガニどうしが、ぶつかって止まらないように)。
-- 人型(Humanoid)は、動いている間に、部品の CanCollide を true に戻すことがある。
-- だから、CanCollide を false にするだけでは足りないので、グループで、AIどうしの衝突を防ぐ。
-- 床(Default グループ)とは、ぶつかったまま(立つ・歩くのため)。CanTouch・CanQuery は、切る
local function disableCollisions(model: Model)
	local groupReady = ensureCollisionGroup()
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = false
			if groupReady then
				descendant.CollisionGroup = COLLISION_GROUP
			end
		end
	end
end

-- 見本を1つ作る(待ちが入る)。人型を作って、ザリガニの見た目をつけ、人型を隠す
local function buildTemplate(): Model
	local created = tryCreateHumanoid()
	local model: Model
	if created ~= nil then
		model = created
	else
		warn("[PreyService] 人型を作れなかったので、簡易モデルを使います")
		model = createFallback()
	end
	model.Name = "PreyTemplate"
	if CrayfishModel.Attach(model) then
		CrayfishModel.HideAvatar(model) -- Attach が成功したときだけ隠す(失敗したら、見えなくなるのを防ぐ)
	else
		WarnOnce.Warn("PreyAttachFailed", "[PreyService] ザリガニの見た目をつけられなかったので、人型を見えるままにします")
	end
	disableCollisions(model)
	return model
end

-- 見本を返す。まだなければ作る(別の場所で作っている最中なら、できるまで待つ)。作れなければ nil
local function ensureTemplate(): Model?
	if template ~= nil then
		return template
	end
	if templateBuilding then
		local deadline = os.clock() + Config.PreyTemplateWaitSeconds
		while templateBuilding and os.clock() < deadline do
			task.wait(math.max(Config.PreyTemplatePollSeconds, MIN_SECONDS))
		end
		return template
	end
	templateBuilding = true
	local ok, result = pcall(buildTemplate)
	templateBuilding = false
	if ok then
		template = result
	else
		warn(`[PreyService] 見本を作れませんでした: {result}`)
	end
	return template
end

-- ===== 出現 =====

-- p が、positions のどの点からも minSpacing 以上はなれているか(横方向)
local function isSpaced(p: Vector3, positions: { Vector3 }, minSpacing: number): boolean
	for _, other in positions do
		if flatDistance(p, other) < minSpacing then
			return false
		end
	end
	return true
end

-- 出現できる範囲のランダムな点:田んぼの北側(スタート地点の南端から遠い側)。壁から FoodWallMargin 以上はなす
local function randomSpawnPoint(random: Random): Vector3
	local center = getFieldCenter()
	local half = Config.FieldSize / 2
	local margin = Config.FoodWallMargin
	local minX = center.X - half + margin
	local maxX = center.X + half - margin
	local minZ = center.Z - half + margin
	local maxZ = math.max(center.Z - half + Config.FieldSize * Config.PreySpawnZoneRatio, minZ) -- 北(-Z)から、一辺の割合だけ
	local x = random:NextNumber(math.min(minX, maxX), math.max(minX, maxX))
	local z = random:NextNumber(minZ, maxZ)
	return Vector3.new(x, center.Y, z)
end

-- count 個の出現位置を選ぶ。お互い FoodMinSpacing 以上はなす(何度か試して、置けなければ、ゆるめる)
local function pickSpawnPoints(count: number, random: Random): { Vector3 }
	local positions: { Vector3 } = {}
	for _ = 1, count do
		local point = randomSpawnPoint(random)
		for _ = 1, Config.FoodPlaceTries do
			if isSpaced(point, positions, Config.FoodMinSpacing) then
				break
			end
			point = randomSpawnPoint(random)
		end
		table.insert(positions, point)
	end
	return positions
end

-- 1ぴきを作って、Prey フォルダに入れる。作れなければ nil。待ちは入らない
local function createPrey(player: Player, point: Vector3, source: Model): Prey?
	local model = source:Clone()
	nextId += 1
	local id = nextId
	model.Name = "Prey_" .. id
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local root = model:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root or not root:IsA("BasePart") then
		model:Destroy()
		return nil
	end

	local params = SetupService.GetDifficultyParams(player)
	local baseSpeed = Config.PreyWalkSpeed * getMultiplier(params, "PreySpeedMultiplier")
	humanoid.WalkSpeed = baseSpeed
	humanoid.UseJumpPower = true
	humanoid.JumpPower = 0 -- ジャンプなし
	humanoid.BreakJointsOnDeath = false
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None -- 名前を表示しない
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff

	-- 足元が、ゆか上面になる高さ(CrayfishModel が見た目の足元を決める考え方と同じ:根っこの中心 = ゆか + HipHeight + 根っこの高さの半分)
	local random = newRandom(id)
	local y = Config.FieldFloorTopY + humanoid.HipHeight + root.Size.Y / 2 + Config.PreySpawnMargin
	model:PivotTo(CFrame.new(point.X, y, point.Z) * CFrame.Angles(0, random:NextNumber(0, 2 * math.pi), 0))
	model:SetAttribute("Hidden", false)
	model:SetAttribute("Jetting", false)
	model.Parent = getFolder()
	FarmerModel.ClaimServerOwnership(model) -- 動きの計算を、サーバーが持つ

	local now = os.clock()
	return {
		Id = id,
		Model = model,
		Humanoid = humanoid,
		Root = root,
		Random = random,
		BaseSpeed = baseSpeed,
		Awareness = Config.PreySightDistance * getMultiplier(params, "PreyAwarenessMultiplier"),
		Mode = "Wander",
		ModeUntil = 0,
		GraceUntil = now + Config.PreyStartGraceSeconds,
		WanderTarget = nil,
		WanderTargetUntil = 0,
		PauseUntil = 0,
		PendingMode = nil,
		ReactAt = 0,
		DiveReadyAt = 0,
		JetReadyAt = 0,
		NextDiveRollAt = 0,
		NextJetRollAt = 0,
		JetDirection = Vector3.zero,
		OriginalTransparency = {},
	}
end

-- ===== 片づけ =====

-- 1ぴきを消す(モデルを Destroy する)。すでに消えていても、エラーにしない
local function destroyPrey(prey: Prey)
	prey.OriginalTransparency = {}
	pcall(function()
		prey.Model:Destroy()
	end)
end

-- 「のこり」を、クライアントが読める Attribute に入れる(nil で消す)
local function publishRemaining(player: Player, remaining: number?)
	pcall(function()
		player:SetAttribute(PREY_REMAINING_ATTRIBUTE, remaining)
	end)
end

-- このプレイヤーの AIザリガニを、すべて消す
local function clearSession(player: Player)
	local session = sessions[player]
	sessions[player] = nil
	if session ~= nil then
		for _, prey in session.Preys do
			destroyPrey(prey)
		end
		session.Preys = {}
	end
	publishRemaining(player, nil)
end

-- ===== 動きの部品(向き・行き先) =====

-- 農家さん(threat)から遠ざかる向き(水平、長さ1)。重なっていて向きが決まらないときは、ランダムな向き
local function awayDirection(from: Vector3, threat: Vector3, random: Random): Vector3
	local offset = Vector3.new(from.X - threat.X, 0, from.Z - threat.Z)
	if offset.Magnitude < TINY then
		local angle = random:NextNumber(0, 2 * math.pi)
		return Vector3.new(math.cos(angle), 0, math.sin(angle))
	end
	return offset.Unit
end

-- 壁に押しつけられている向きの成分を消して、壁にそって進む向きにする(仕様書 016 の 4)。
--   ・壁に向かう成分(X か Z)を、0 にする。
--   ・残りがほぼ0(壁にほぼ垂直)なら、壁にそって、農家さん(threat)から遠ざかる側へすべる。
--   ・角(両方の壁)に追いつめられたら、Vector3.zero(動けない = つかまりやすい)。
-- 戻り値は、水平で長さ 1(または Vector3.zero)
local function slideAlongWalls(position: Vector3, direction: Vector3, threat: Vector3): Vector3
	local center = getFieldCenter()
	local half = getPlayableHalf()
	local edgeDistance = half - Config.PreyWallSlideEpsilon
	local relX = position.X - center.X
	local relZ = position.Z - center.Z
	local x = direction.X
	local z = direction.Z
	local blockedX = math.abs(relX) >= edgeDistance and x * relX > 0
	local blockedZ = math.abs(relZ) >= edgeDistance and z * relZ > 0
	if blockedX and blockedZ then
		return Vector3.zero
	end
	if blockedX then
		x = 0
	end
	if blockedZ then
		z = 0
	end
	local remain = Vector3.new(x, 0, z)
	if remain.Magnitude >= Config.PreyWallSlideMinRatio then
		return remain.Unit
	end
	-- ほぼ壁に垂直:壁にそってすべる。農家さんから遠ざかる側(重なっていれば、中心に近い側)
	if blockedX then
		local sign = if math.abs(position.Z - threat.Z) > TINY then signOf(position.Z - threat.Z) else signOf(-relZ)
		return Vector3.new(0, 0, sign)
	elseif blockedZ then
		local sign = if math.abs(position.X - threat.X) > TINY then signOf(position.X - threat.X) else signOf(-relX)
		return Vector3.new(sign, 0, 0)
	end
	return if remain.Magnitude > TINY then remain.Unit else Vector3.zero
end

-- 向き direction に PreyFleeStepStuds だけ進んだ点(歩き回ってよい範囲の中に収める)。高さは position のまま
local function targetFromDirection(position: Vector3, direction: Vector3): Vector3
	local center = getFieldCenter()
	local half = getPlayableHalf()
	local goalX = math.clamp(position.X + direction.X * Config.PreyFleeStepStuds, center.X - half, center.X + half)
	local goalZ = math.clamp(position.Z + direction.Z * Config.PreyFleeStepStuds, center.Z - half, center.Z + half)
	return Vector3.new(goalX, position.Y, goalZ)
end

-- 農家さんから逃げる向き(壁にそう。角なら Vector3.zero)
local function escapeDirection(prey: Prey, position: Vector3, threat: Vector3): Vector3
	return slideAlongWalls(position, awayDirection(position, threat, prey.Random), threat)
end

-- 歩き回ってよい範囲の、ランダムな点
local function randomWanderPoint(prey: Prey, y: number): Vector3
	local center = getFieldCenter()
	local half = getPlayableHalf()
	local x = prey.Random:NextNumber(center.X - half, center.X + half)
	local z = prey.Random:NextNumber(center.Z - half, center.Z + half)
	return Vector3.new(x, y, z)
end

-- 歩く速さを決める(変わったときだけ代入する)
local function setSpeed(prey: Prey, speed: number)
	if prey.Humanoid.WalkSpeed ~= speed then
		prey.Humanoid.WalkSpeed = speed
	end
end

-- ===== 潜る・ジェット =====

-- 潜る見た目を変える対象の部品:CrayfishVisual の中だけ(人型は隠してあるので触らない)
local function getVisualParts(model: Model): { BasePart }
	local parts: { BasePart } = {}
	local visual = model:FindFirstChild(VISUAL_FOLDER_NAME)
	if visual == nil then
		return parts
	end
	for _, descendant in visual:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		end
	end
	return parts
end

-- 噴射の粒子(CrayfishModel でつけた JetEmitter)を出す・止める。なくても、エラーにしない
local function setJetEmitter(model: Model, enabled: boolean)
	local visual = model:FindFirstChild(VISUAL_FOLDER_NAME)
	if visual == nil then
		return
	end
	local found = visual:FindFirstChild("JetEmitter", true)
	if found ~= nil and found:IsA("ParticleEmitter") then
		found.Enabled = enabled
	end
end

-- 潜る:動けなくして、半透明にして、Attribute Hidden を true にする
local function startDive(prey: Prey, now: number)
	prey.Mode = "Dive"
	prey.ModeUntil = now + math.max(Config.PreyDiveSeconds, MIN_SECONDS)
	setSpeed(prey, 0)
	prey.Humanoid:MoveTo(prey.Root.Position) -- その場で止まる
	prey.OriginalTransparency = {}
	for _, part in getVisualParts(prey.Model) do
		prey.OriginalTransparency[part] = part.Transparency
		part.Transparency = math.max(part.Transparency, Config.DiveTransparency) -- もともと透明な部品は、見えないまま
	end
	prey.Model:SetAttribute("Hidden", true)
end

-- 浮上する:元の見た目に戻して、ため直しを始める。逃げる状態に戻る(まだ近ければ逃げ続け、離れていれば、うろうろに戻る)
local function endDive(prey: Prey, now: number)
	for part, original in prey.OriginalTransparency do
		if part.Parent ~= nil then
			part.Transparency = original
		end
	end
	prey.OriginalTransparency = {}
	prey.Model:SetAttribute("Hidden", false)
	setSpeed(prey, prey.BaseSpeed)
	prey.DiveReadyAt = now + Config.PreyDiveCooldownSeconds
	prey.Mode = "Flee"
	prey.WanderTarget = nil
end

-- ジェット:遠ざかる向きに、JetSeconds のあいだ、JetSpeedMultiplier 倍の速さで走る
local function startJet(prey: Prey, now: number, direction: Vector3)
	prey.Mode = "Jet"
	prey.ModeUntil = now + math.max(Config.JetSeconds, MIN_SECONDS)
	prey.JetDirection = direction
	setSpeed(prey, prey.BaseSpeed * Config.JetSpeedMultiplier)
	prey.Model:SetAttribute("Jetting", true)
	setJetEmitter(prey.Model, true)
end

-- 噴射を終える:ため直しを始めて、逃げる状態に戻る(まだ近ければ逃げ続け、離れていれば、うろうろに戻る)
local function endJet(prey: Prey, now: number)
	prey.Model:SetAttribute("Jetting", false)
	setJetEmitter(prey.Model, false)
	setSpeed(prey, prey.BaseSpeed)
	prey.JetReadyAt = now + Config.PreyJetCooldownSeconds
	prey.Mode = "Flee"
end

-- ===== 判断(状態の切り替え) =====

-- 反応の遅れのあと、状態を変えてよいか(その間に、状況が変わっていないか)
local function canApply(prey: Prey, mode: PreyMode, now: number, distance: number): boolean
	if mode == "Jet" then
		return distance <= Config.PreyJetDistance and now >= prey.JetReadyAt
	elseif mode == "Dive" then
		return distance <= Config.PreyDiveDistance and now >= prey.DiveReadyAt
	elseif mode == "Flee" then
		return distance <= prey.Awareness
	end
	return false
end

-- 状態を変えるのを、反応の遅れのぶんだけ待たせる
local function schedule(prey: Prey, mode: PreyMode, now: number)
	prey.PendingMode = mode
	prey.ReactAt = now + randomSeconds(prey.Random, Config.PreyReactionSecondsMin, Config.PreyReactionSecondsMax)
end

-- 待たせていた状態に、実際に変える。変えられなければ(角に追いつめられてジェットできない、など)何もしない
local function applyPending(prey: Prey, mode: PreyMode, now: number, position: Vector3, threat: Vector3)
	if mode == "Dive" then
		startDive(prey, now)
	elseif mode == "Jet" then
		local direction = escapeDirection(prey, position, threat)
		if direction.Magnitude > TINY then
			startJet(prey, now, direction)
		end
	elseif mode == "Flee" then
		prey.Mode = "Flee"
		prey.WanderTarget = nil
	end
end

-- 潜る・ジェットの「くじ」を引く(使えて、くじの間隔が過ぎていて、近いとき)。当たったら、反応の遅れのあとに発動するよう、待たせる。
-- はずれたら、PreyAbilityRollSeconds のあいだ、引かない(毎回引くと、ほぼ必ず当たるため)
local function rollAbilities(prey: Prey, now: number, distance: number)
	if distance <= Config.PreyJetDistance and now >= prey.JetReadyAt and now >= prey.NextJetRollAt then
		if prey.Random:NextNumber() < Config.PreyJetChance then
			schedule(prey, "Jet", now)
			return
		end
		prey.NextJetRollAt = now + math.max(Config.PreyAbilityRollSeconds, MIN_SECONDS)
	end
	if distance <= Config.PreyDiveDistance and now >= prey.DiveReadyAt and now >= prey.NextDiveRollAt then
		if prey.Random:NextNumber() < Config.PreyDiveChance then
			schedule(prey, "Dive", now)
			return
		end
		prey.NextDiveRollAt = now + math.max(Config.PreyAbilityRollSeconds, MIN_SECONDS)
	end
end

-- 農家さんとの距離を見て、状態を変える(Wander・Flee のとき)。農家さんがいなければ(threat が nil)、うろうろ
local function updateMode(prey: Prey, now: number, position: Vector3, threat: Vector3?)
	if threat == nil or now < prey.GraceUntil then
		prey.PendingMode = nil -- 出現直後の猶予の間と、農家さんがいない間は、逃げない
		if prey.Mode == "Flee" then
			prey.Mode = "Wander"
			prey.WanderTarget = nil
		end
		return
	end
	local distance = flatDistance(position, threat)
	local pending = prey.PendingMode
	if pending ~= nil then
		if now < prey.ReactAt then
			return -- まだ反応していない(遅れの間は、いまの動きを続ける)
		end
		prey.PendingMode = nil
		if canApply(prey, pending, now, distance) then
			applyPending(prey, pending, now, position, threat)
		end
		return
	end
	if prey.Mode == "Flee" and distance > prey.Awareness * Config.PreyCalmRatio then
		prey.Mode = "Wander" -- 十分はなれた:落ち着く
		prey.WanderTarget = nil
		return
	end
	rollAbilities(prey, now, distance)
	if prey.PendingMode == nil and prey.Mode == "Wander" and distance <= prey.Awareness then
		schedule(prey, "Flee", now)
	end
end

-- ===== 動き =====

-- うろうろ:行き先へ歩く。着いたら、確率で立ち止まる。着かなければ、時間切れで選び直す
local function wander(prey: Prey, now: number, position: Vector3)
	setSpeed(prey, prey.BaseSpeed * Config.PreyWanderSpeedRatio)
	if now < prey.PauseUntil then
		return -- 立ち止まっている
	end
	local target = prey.WanderTarget
	if target ~= nil then
		local arrived = flatDistance(position, target) <= Config.PreyWanderArriveDistance
		if arrived and prey.Random:NextNumber() < Config.PreyWanderPauseChance then
			local pauseSeconds = randomSeconds(prey.Random, Config.PreyWanderPauseSecondsMin, Config.PreyWanderPauseSecondsMax)
			prey.PauseUntil = now + pauseSeconds
			prey.WanderTarget = nil
			prey.Humanoid:MoveTo(position) -- その場で止まる
			return
		end
		if arrived or now >= prey.WanderTargetUntil then
			target = nil
		end
	end
	if target == nil then
		target = randomWanderPoint(prey, position.Y)
		prey.WanderTarget = target
		prey.WanderTargetUntil = now + math.max(Config.PreyWanderTargetTimeoutSeconds, MIN_SECONDS)
	end
	prey.Humanoid:MoveTo(target)
end

-- 逃げる:農家さんから遠ざかる向きの点へ、走る(壁にそう)。角に追いつめられたら、動けない
local function flee(prey: Prey, position: Vector3, threat: Vector3)
	setSpeed(prey, prey.BaseSpeed)
	local direction = escapeDirection(prey, position, threat)
	if direction.Magnitude > TINY then
		prey.Humanoid:MoveTo(targetFromDirection(position, direction))
	else
		prey.Humanoid:MoveTo(position)
	end
end

-- ジェット中:決めた向きに走り続ける(壁にぶつかる向きなら、壁にそう)
local function jetMove(prey: Prey, position: Vector3, threat: Vector3?)
	local direction = slideAlongWalls(position, prey.JetDirection, threat or position)
	if direction.Magnitude > TINY then
		prey.Humanoid:MoveTo(targetFromDirection(position, direction))
	end
end

-- 体がまだ使えるか(壊れた・消えた・倒れたら false)
local function isUsable(prey: Prey): boolean
	return prey.Model.Parent ~= nil
		and prey.Humanoid.Parent ~= nil
		and prey.Humanoid.Health > 0
		and prey.Root.Parent ~= nil
end

-- 田んぼの外・ゆかの下に落ちたら、出現位置の範囲に戻す
local function rescueIfFallen(prey: Prey)
	local position = prey.Root.Position
	if position.Y >= Config.FieldFloorTopY - Config.FieldWallHeight then
		return
	end
	local point = randomSpawnPoint(prey.Random)
	local y = Config.FieldFloorTopY + prey.Humanoid.HipHeight + prey.Root.Size.Y / 2 + Config.PreySpawnMargin
	prey.Model:PivotTo(CFrame.new(point.X, y, point.Z))
	WarnOnce.Warn("PreyFell", "[PreyService] AIザリガニが落ちたので、田んぼの北側に戻しました")
end

-- 1ぴきの判断1回ぶん。農家さんの位置(いなければ nil)を受け取る
local function thinkPrey(prey: Prey, now: number, farmerPosition: Vector3?)
	rescueIfFallen(prey)
	local position = prey.Root.Position
	if prey.Mode == "Dive" then
		if now < prey.ModeUntil then
			return -- 潜っている間は、動けない
		end
		endDive(prey, now)
	elseif prey.Mode == "Jet" then
		if now < prey.ModeUntil then
			jetMove(prey, position, farmerPosition)
			return
		end
		endJet(prey, now)
	end

	updateMode(prey, now, position, farmerPosition)
	if prey.Mode == "Dive" then
		return -- いま潜った(動けない)
	elseif prey.Mode == "Jet" then
		jetMove(prey, position, farmerPosition)
	elseif prey.Mode == "Flee" and farmerPosition ~= nil then
		flee(prey, position, farmerPosition)
	else
		wander(prey, now, position)
	end
end

-- ===== つかまえる判定 =====

-- 遊んでいて生きているプレイヤーの HumanoidRootPart。いなければ nil
local function getFarmerRoot(player: Player): BasePart?
	if not RoundService.IsPlaying(player) then
		return nil
	end
	local character = player.Character
	if character == nil then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or humanoid.Health <= 0 or not root or not root:IsA("BasePart") then
		return nil
	end
	return root
end

-- 1ぴきをつかまえる:点を足して、消して、のこりを更新する。点が入らなければ(ラウンド外など)つかまえない。
-- つかまえたら true
local function catchPrey(session: Session, prey: Prey): boolean
	local player = session.Player
	if not ScoreService.AddPoints(player, Config.PreyCatchPoints) then
		return false
	end
	session.Preys[prey.Id] = nil
	session.Remaining = math.max(session.Remaining - 1, 0)
	session.CaughtCount += 1
	destroyPrey(prey)
	publishRemaining(player, session.Remaining)
	return true
end

-- のこりが 0 になっていたら、ラウンドを終える(終わりを知らせると、このまとまりは消える)。終えたら true。
--   ・つかまえた数が 1 以上: クリア(ぜんいん つかまえた!)
--   ・つかまえた数が 0(壊れて数から外れた、出し直せなかった、など): クリアにしない。「にげられた…」(Caught)で終える
local function finishIfNoneLeft(session: Session): boolean
	if session.Remaining > 0 then
		return false
	end
	local player = session.Player
	if session.CaughtCount > 0 then
		RoundService.NotifyAllPreyCaught(player)
	else
		RoundService.NotifyCaught(player)
	end
	return true
end

-- 近くにいるザリガニを、つかまえる。距離は横方向(XZ):潜っていなければ FarmerCatchDistance、潜っていれば FarmerCatchHiddenDistance
-- (どちらも × 巨人の実際の大きさ)。ぜんぶつかまえて、ラウンドを終えたら true
local function catchNearby(session: Session, farmerPosition: Vector3): boolean
	local player = session.Player
	local scale = FarmerPlayer.GetScale(player)
	local normalLimit = Config.FarmerCatchDistance * scale
	local hiddenLimit = Config.FarmerCatchHiddenDistance * scale
	for _, prey in session.Preys do
		if isUsable(prey) then
			local limit = if prey.Mode == "Dive" then hiddenLimit else normalLimit
			if flatDistance(prey.Root.Position, farmerPosition) <= limit then
				catchPrey(session, prey)
			end
		end
	end
	return finishIfNoneLeft(session) -- ぜんぶつかまえた:クリア(終わったら true)
end

-- 壊れたAIを、見本の複製で、出現範囲のランダムな位置に、1ぴき出し直す。出せたら Prey、出せなければ nil
local function respawnPrey(session: Session, random: Random): Prey?
	local source = template
	if source == nil then
		return nil
	end
	local ok, result = pcall(createPrey, session.Player, randomSpawnPoint(random), source)
	if ok then
		return result
	end
	return nil
end

-- 壊れたザリガニを、つかまえた扱いにしない(点も、つかまえた数も、増やさない)。
-- 新しい個体に出し直す(のこりの数は、そのまま)。出し直せなければ、数から外す(ずっと終わらなくなるのを防ぐ)。
-- 注意:Preys を for で回している最中には呼ばない(表に新しい番号を足すため)
local function replaceBroken(session: Session, broken: Prey)
	WarnOnce.Warn("PreyBroken", "[PreyService] 壊れたAIザリガニがいたので、出し直します")
	session.Preys[broken.Id] = nil
	destroyPrey(broken)
	local fresh = respawnPrey(session, broken.Random)
	if fresh ~= nil then
		session.Preys[fresh.Id] = fresh
		return
	end
	WarnOnce.Warn("PreyRespawnFailed", "[PreyService] 壊れたAIザリガニを出し直せなかったので、数から外しました")
	session.Remaining = math.max(session.Remaining - 1, 0)
	publishRemaining(session.Player, session.Remaining)
end

-- 1人ぶんの判断1回ぶん。つかまえる判定 → 各ザリガニの判断(1ぴきのエラーで、ほかを止めない)
local function updateSession(session: Session, now: number)
	local player = session.Player
	if player.Parent == nil or not RoundService.IsPlaying(player) then
		return -- いなくなった・遊んでいない(結果の画面など)間は、何もしない
	end
	local root = getFarmerRoot(player)
	local farmerPosition: Vector3? = if root ~= nil then root.Position else nil
	if farmerPosition ~= nil and catchNearby(session, farmerPosition) then
		return
	end
	local brokenPreys: { Prey } = {} -- 壊れたもの(回している最中に表を変えないように、あとでまとめて出し直す)
	for _, prey in session.Preys do
		if not isUsable(prey) then
			table.insert(brokenPreys, prey)
		else
			local ok, err = pcall(thinkPrey, prey, now, farmerPosition)
			if not ok then
				WarnOnce.Warn("PreyThink", `[PreyService] AIザリガニの判断中にエラー: {err}`)
			end
		end
	end
	for _, broken in brokenPreys do
		replaceBroken(session, broken)
	end
	if sessions[player] == session then
		finishIfNoneLeft(session) -- 出し直せなくて、のこりが 0 になったとき(つかまえた数が 0 なら「にげられた…」)
	end
end

-- ===== 判断のループ =====

-- 判断1回ぶん(全員)。1人のエラーで、ループが止まらない
local function thinkAll()
	local now = os.clock()
	for _, session in sessions do
		local ok, err = pcall(updateSession, session, now)
		if not ok then
			WarnOnce.Warn("PreyUpdate", `[PreyService] 判断中にエラー: {err}`)
		end
	end
end

-- 判断のループを始める。同時に動くのは1つだけ(古いループは、番号が合わなくなって終わる)。まとまりがなくなったら、自分で終わる
local function startLoop()
	if loopRunning then
		return
	end
	loopToken += 1
	local myToken = loopToken
	loopRunning = true
	task.spawn(function()
		while true do
			task.wait(math.max(Config.EnemyTickSeconds, MIN_SECONDS))
			if myToken ~= loopToken then
				break -- Clear などで、新しい世代になった
			end
			if next(sessions) == nil then
				break -- 動かすものがない
			end
			thinkAll()
		end
		if myToken == loopToken then
			loopRunning = false -- 引き継がれたときは、新しいループの印を消さない
		end
	end)
end

-- ===== 公開する関数 =====

-- 出せなかったとき(見本がない・1ぴきも作れない):AIなしで 300 秒が進まないように、ラウンドを「にげられた…」(Caught。つかまえた数 0)で、すぐ終わらせる。
-- まず自分のまとまりを消してから、RoundService に知らせる
local function abortSpawn(player: Player)
	clearSession(player)
	RoundService.NotifyCaught(player)
end

-- 農家さんのラウンドが始まるとき、難易度の数(PreyCount)だけ、AIザリガニを出す。
-- 見本ができるまで待つことがある。待っている間に、やり直し・メニュー戻りで消されたら、出さない
function PreyService.SpawnFor(player: Player)
	clearSession(player) -- 同じ人の古いものを消す
	local count = getPreyCount(SetupService.GetDifficultyParams(player))
	-- まとまり(session)を先に登録する。待っている間に Clear などで消されたら、表の中身が別物になるので、それで見分ける(世代の代わり)
	local session: Session = { Player = player, Preys = {}, Remaining = count, CaughtCount = 0 }
	sessions[player] = session
	publishRemaining(player, count)

	local source = ensureTemplate() -- 待ちが入ることがある
	if sessions[player] ~= session or player.Parent == nil then
		return -- 待っている間に、消された
	end
	if source == nil then
		warn("[PreyService] 見本がないので、もう1回だけ、作り直します")
		source = ensureTemplate() -- 見本づくりを、あと1回だけ、やり直す(待ちが入る)
		if sessions[player] ~= session or player.Parent == nil then
			return -- 待っている間に、消された
		end
	end
	if source == nil then
		warn("[PreyService] 見本を作れないので、AIザリガニを出せません。ラウンドを「にげられた…」で終わらせます")
		abortSpawn(player)
		return
	end

	local points = pickSpawnPoints(count, newRandom(0))
	for _, point in points do
		local prey = createPrey(player, point, source)
		if prey ~= nil then
			session.Preys[prey.Id] = prey
		else
			session.Remaining = math.max(session.Remaining - 1, 0) -- 作れなかったぶんは、のこりから外す
		end
	end
	publishRemaining(player, session.Remaining)
	if session.Remaining <= 0 then
		warn("[PreyService] AIザリガニを1ぴきも作れませんでした。ラウンドを「にげられた…」で終わらせます")
		abortSpawn(player)
		return
	end
	startLoop()
end

-- すべてのAIザリガニを消す(やり直し・メニュー戻りで)。古いループも、番号が合わなくなって終わる
function PreyService.Clear()
	loopToken += 1
	loopRunning = false
	for player in sessions do
		clearSession(player)
	end
end

-- ラウンドが始まったとき:農家さんなら出す。ザリガニなら、のこりの表示を消す
local function onRoundStart(player: Player, role: string)
	if role == "Farmer" then
		PreyService.SpawnFor(player)
	else
		clearSession(player)
	end
end

-- ラウンドが終わったとき(クリア・時間切れ・つかまった):結果の画面の間は、AIザリガニを消す
local function onRoundEnd(player: Player, _role: string, _endState: string)
	clearSession(player)
end

function PreyService.Start()
	if started then
		return
	end
	started = true

	local old = Workspace:FindFirstChild(FOLDER_NAME)
	if old then
		old:Destroy()
	end
	folder = nil
	getFolder()

	RoundService.OnRestart(PreyService.Clear)
	RoundService.OnRoundStart(onRoundStart)
	RoundService.OnRoundEnd(onRoundEnd)
	Players.PlayerRemoving:Connect(clearSession)

	-- 見本を、先に作っておく(人型の作成は待ちが入るので、「スタート」を押す前に済ませる)
	task.spawn(ensureTemplate)
end

return PreyService
