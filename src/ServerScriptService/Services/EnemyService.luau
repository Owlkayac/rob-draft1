--!strict
-- 天敵「農家さん」の動きの頭脳。仕様書 002。
-- 状態: Patrol(見回り)/ Chase(追跡)/ Search(探す)。
-- 捕獲は状態ではなく、追跡中の判定。見た目は FarmerModel(別ファイル)が担当する。
-- 動きと捕獲の判定は、すべてサーバーで行う。

local PathfindingService = game:GetService("PathfindingService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local CrayfishService = require(script.Parent.CrayfishService)
local FieldService = require(script.Parent.FieldService)
local RoundService = require(script.Parent.RoundService)

-- 見た目の部品は ServerStorage/Modules にある(Rojo の対応は default.project.json)
local modulesFolder = ServerStorage:WaitForChild("Modules", 10)
assert(modulesFolder, "[EnemyService] ServerStorage/Modules が見つかりません")
local farmerModelScript = modulesFolder:WaitForChild("FarmerModel", 10)
assert(farmerModelScript, "[EnemyService] FarmerModel が見つかりません")
local FarmerModel = require(farmerModelScript :: ModuleScript)

type StateName = "Patrol" | "Chase" | "Search"

-- 見える相手1人ぶんの情報
type Target = {
	Player: Player,
	Position: Vector3,
	Distance: number, -- 横方向(XZ)の距離
}

-- 農家さんの体の部品(毎回、存在を確認して取り出す)
type Parts = {
	Model: Model,
	Humanoid: Humanoid,
	Root: BasePart,
}

local EnemyService = {}

-- 農家さん本体
local farmer: Model? = nil
local spawnPosition = Vector3.zero -- 出現位置(やり直しで戻す場所)
local spawnIndex = 1 -- 出現位置にした見回り地点の番号
local patrolPoints: { Vector3 } = {}
local started = false
local spawning = false -- 農家さんを作っている最中か(二重に作らないための印)
-- 動きのループの番号。新しいループを始めるたびに増やし、古いループは自分で終わる
local loopToken = 0
local loopRunning = false -- いま動きのループが動いているか

-- 状態と、追跡の記憶
local state: StateName = "Patrol"
local patrolIndex = 1
local chasePlayer: Player? = nil -- 追っている相手
local lastSeenPosition: Vector3? = nil -- 最後に見えた位置
local lostSightSince: number? = nil -- 見えなくなった時刻(os.clock)
local searchEndAt = 0 -- 探し終わる時刻(os.clock)

-- 経路(Path)の記憶
local waypoints: { PathWaypoint } = {}
local waypointIndex = 1
local lastPathAt = -math.huge -- 最後に経路を作った時刻
-- やり直しや状態変更で、古い経路計算の結果を捨てるための番号
local generation = 0

-- 横方向(XZ)だけの距離。高さの違いは無視する
local function flatDistance(a: Vector3, b: Vector3): number
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

-- 農家さんの体を取り出す。壊れていたり、倒れていたら nil
local function getParts(): Parts?
	local model = farmer
	if not model or not model.Parent then
		return nil
	end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local root = model:FindFirstChild("HumanoidRootPart")
	if not humanoid or humanoid.Health <= 0 or not root or not root:IsA("BasePart") then
		return nil
	end
	return { Model = model, Humanoid = humanoid, Root = root }
end

-- 経路の記憶を消す(次の移動で作り直す)
local function clearPath()
	generation += 1
	waypoints = {}
	waypointIndex = 1
	lastPathAt = -math.huge
end

-- その場で止まる
local function stopMoving(parts: Parts)
	parts.Humanoid:MoveTo(parts.Root.Position)
end

-- 生きているプレイヤーの HumanoidRootPart を返す(遊んでいない・倒れている人は nil)
local function getPlayingRoot(player: Player): BasePart?
	if not RoundService.IsPlaying(player) then
		return nil
	end
	local character = player.Character
	if not character then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or humanoid.Health <= 0 or not root or not root:IsA("BasePart") then
		return nil
	end
	return root
end

-- 「いちばん近い、見える相手」を探す。
-- 戻り値: (見える相手 or nil, 遊んでいる人が1人でもいるか)
local function scanPlayers(fromPosition: Vector3): (Target?, boolean)
	local best: Target? = nil
	local anyPlaying = false
	for _, player in Players:GetPlayers() do
		local root = getPlayingRoot(player)
		if root then
			anyPlaying = true
			local distance = flatDistance(fromPosition, root.Position)
			local sight = Config.FarmerSightDistance * RoundService.GetSightMultiplier(player)
			local visible = distance <= sight and not CrayfishService.IsHidden(player)
			if visible and (best == nil or distance < best.Distance) then
				best = { Player = player, Position = root.Position, Distance = distance }
			end
		end
	end
	return best, anyPlaying
end

-- 目的地へ向かって歩く。EnemyRepathSeconds ごとに経路を作り直し、
-- 作れなければ、目的地へ直接 MoveTo する。(この関数は止まることがある)
local function walkTo(parts: Parts, destination: Vector3)
	local now = os.clock()
	if now - lastPathAt >= Config.EnemyRepathSeconds then
		lastPathAt = now
		local myGeneration = generation
		local path = PathfindingService:CreatePath({
			AgentRadius = Config.PathAgentRadius,
			AgentHeight = Config.PathAgentHeight,
			AgentCanJump = false,
		})
		local ok = pcall(function()
			path:ComputeAsync(parts.Root.Position, destination)
		end)
		-- 待っている間に、やり直しや状態変更・破壊があったら、結果を捨てる
		if myGeneration ~= generation or not parts.Root.Parent then
			return
		end
		if ok and path.Status == Enum.PathStatus.Success then
			waypoints = path:GetWaypoints()
		else
			waypoints = {} -- 経路が作れなかった:直接向かう
		end
		waypointIndex = 1
	end

	-- 着いた点は飛ばして、次の点へ向かう
	local rootPosition = parts.Root.Position
	while waypointIndex <= #waypoints
		and flatDistance(rootPosition, waypoints[waypointIndex].Position) <= Config.WaypointReachDistance do
		waypointIndex += 1
	end
	if waypointIndex <= #waypoints then
		parts.Humanoid:MoveTo(waypoints[waypointIndex].Position)
	else
		parts.Humanoid:MoveTo(destination)
	end
end

-- ===== 状態の切り替え =====

-- いちばん近い見回り地点の番号
local function nearestPatrolIndex(position: Vector3): number
	local bestIndex = 1
	local bestDistance = math.huge
	for index, point in patrolPoints do
		local distance = flatDistance(position, point)
		if distance < bestDistance then
			bestDistance = distance
			bestIndex = index
		end
	end
	return bestIndex
end

local function enterPatrol(parts: Parts)
	state = "Patrol"
	parts.Humanoid.WalkSpeed = Config.FarmerWalkSpeed
	chasePlayer = nil
	lastSeenPosition = nil
	lostSightSince = nil
	patrolIndex = nearestPatrolIndex(parts.Root.Position)
	clearPath()
end

local function enterChase(parts: Parts, target: Target)
	state = "Chase"
	parts.Humanoid.WalkSpeed = Config.FarmerChaseSpeed
	chasePlayer = target.Player
	lastSeenPosition = target.Position
	lostSightSince = nil
	clearPath()
end

local function enterSearch(parts: Parts)
	state = "Search"
	parts.Humanoid.WalkSpeed = Config.FarmerWalkSpeed
	searchEndAt = os.clock() + Config.FarmerSearchSeconds
	lostSightSince = nil
	clearPath()
	stopMoving(parts) -- 歩き回らず、その場で探す
end

-- ===== 状態ごとの1回ぶんの判断 =====

local function updatePatrol(parts: Parts, target: Target?, anyPlaying: boolean)
	if target then
		enterChase(parts, target)
		return
	end
	if not anyPlaying then
		stopMoving(parts) -- 遊んでいる人がいない間は、その場で止まる
		return
	end
	local point = patrolPoints[patrolIndex]
	if flatDistance(parts.Root.Position, point) <= Config.PatrolArriveDistance then
		patrolIndex = patrolIndex % #patrolPoints + 1 -- 次の地点へ(順番に回る)
		clearPath()
		point = patrolPoints[patrolIndex]
	end
	walkTo(parts, point)
end

-- 見えなくなっているときの追跡(潜った・遠くへ離れた・いなくなった)
local function updateChaseLost(parts: Parts)
	local now = os.clock()
	local since = lostSightSince
	if since == nil then
		since = now
		lostSightSince = now
	end
	local lastSeen = lastSeenPosition
	if now - since >= Config.FarmerLoseSightSeconds or lastSeen == nil then
		enterPatrol(parts)
		return
	end
	local diver = chasePlayer
	local arrived = flatDistance(parts.Root.Position, lastSeen) <= Config.PatrolArriveDistance
	if diver and CrayfishService.IsHidden(diver) and arrived then
		enterSearch(parts) -- 潜った場所に着いたので、探す
		return
	end
	if arrived then
		stopMoving(parts)
		return
	end
	walkTo(parts, lastSeen)
end

local function updateChase(parts: Parts, target: Target?)
	if not target then
		updateChaseLost(parts)
		return
	end
	chasePlayer = target.Player
	lastSeenPosition = target.Position
	lostSightSince = nil
	-- 捕獲の判定。この時点で target は「潜っていない」ことが確定している
	if target.Distance <= Config.FarmerCatchDistance then
		RoundService.NotifyCaught(target.Player)
		stopMoving(parts)
		enterPatrol(parts)
		return
	end
	walkTo(parts, target.Position)
end

local function updateSearch(parts: Parts, target: Target?)
	if target then
		enterChase(parts, target) -- 探している間に見つけた
		return
	end
	if os.clock() >= searchEndAt then
		enterPatrol(parts)
		return
	end
	stopMoving(parts)
end

-- 判断1回ぶん(組み込みの tick() と名前が重ならないよう think)。農家さんがいなくなったら false(ループを終える)
local function think(): boolean
	local parts = getParts()
	if not parts then
		return false
	end
	local target, anyPlaying = scanPlayers(parts.Root.Position)
	if state == "Patrol" then
		updatePatrol(parts, target, anyPlaying)
	elseif state == "Chase" then
		updateChase(parts, target)
	else
		updateSearch(parts, target)
	end
	return true
end

-- 出現位置:見回り地点のうち、スタート地点(南端)からいちばん遠いもの
local function chooseSpawn()
	local startPosition = Vector3.new(0, 0, Config.FieldSize / 2 - Config.SpawnEdgeOffset)
	local farthest = 0
	for index, point in patrolPoints do
		local distance = flatDistance(point, startPosition)
		if distance > farthest then
			farthest = distance
			spawnIndex = index
		end
	end
	spawnPosition = patrolPoints[spawnIndex]
end

-- Enemies フォルダを返す(なければ作る)
local function getEnemiesFolder(): Instance
	local folder = Workspace:FindFirstChild("Enemies")
	if folder then
		return folder
	end
	local newFolder = Instance.new("Folder")
	newFolder.Name = "Enemies"
	newFolder.Parent = Workspace
	return newFolder
end

-- 農家さんを「作る」処理(動きのループは始めない)。成功したら true。
-- 古い農家さんが残っていたら片づける。人型の作成は待ちが入る
local function spawnFarmer(): boolean
	if spawning then
		return false
	end
	spawning = true

	local ok, result = pcall(FarmerModel.Create)
	if not ok then
		spawning = false
		warn(`[EnemyService] 農家さんを作れませんでした: {result}`)
		return false
	end
	local model = result :: Model

	local old = farmer
	farmer = nil
	if old then
		old:Destroy()
	end

	model:PivotTo(CFrame.new(spawnPosition))
	model.Parent = getEnemiesFolder()
	FarmerModel.ClaimServerOwnership(model) -- Workspace に入れたあとで、動きの計算をサーバーにする
	farmer = model

	local parts = getParts()
	if parts then
		enterPatrol(parts)
		patrolIndex = spawnIndex % #patrolPoints + 1 -- 出現位置の「次」の地点から回る
	end
	spawning = false
	return parts ~= nil
end

-- 動きの「ループ」を始める。同時に動くのは1つだけ(古いループは番号が合わなくなって終わる)。
-- 動きの判断は、EnemyTickSeconds ごと(毎フレームは使わない)
local function startLoop()
	loopToken += 1
	local myToken = loopToken
	loopRunning = true
	task.spawn(function()
		local reason = "不明な理由"
		while true do
			task.wait(Config.EnemyTickSeconds)
			if myToken ~= loopToken then
				reason = "新しいループに引き継いだ"
				break
			end
			local thinkOk, alive = pcall(think)
			if not thinkOk then
				warn(`[EnemyService] 判断中にエラー: {alive}`)
			elseif alive == false then
				reason = "農家さんが壊れた・倒れた・いなくなった"
				break
			end
		end
		warn(`[EnemyService] 動きのループを終えます: {reason}`)
		if myToken == loopToken then
			loopRunning = false -- 引き継がれたときは、新しいループの印を消さない
		end
	end)
end

-- 「もう一度」でやり直すとき。
-- 農家さんが壊れている・死んでいる・Root がないなら、作り直してループも始め直す。
-- 無事なら、位置を出現位置に戻して見回りに戻すだけ
local function onRestart()
	local parts = getParts()
	if not parts then
		if spawning then
			return -- すでに作り直している最中
		end
		warn("[EnemyService] 農家さんが使えないので、作り直します")
		if spawnFarmer() then
			startLoop()
		end
		return
	end
	parts.Model:PivotTo(CFrame.new(spawnPosition))
	enterPatrol(parts)
	patrolIndex = spawnIndex % #patrolPoints + 1 -- 出現位置の「次」の地点から回る
	stopMoving(parts)
	if not loopRunning then
		startLoop() -- ループが止まっていたら動かし直す
	end
end

function EnemyService.Start()
	if started then
		return
	end
	started = true

	patrolPoints = FieldService.GetPatrolPoints()
	if #patrolPoints == 0 then
		warn("[EnemyService] 見回り地点がないので、農家さんを出せません")
		return
	end
	chooseSpawn()

	-- 最初に作れなくても、「もう一度」のときに作り直せるように、先に登録しておく
	RoundService.OnRestart(onRestart)

	if spawnFarmer() then
		startLoop()
	else
		warn("[EnemyService] 最初の農家さんを作れませんでした。「もう一度」で作り直します")
	end
end

return EnemyService
