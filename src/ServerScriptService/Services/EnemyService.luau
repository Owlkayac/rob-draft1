--!strict
-- 天敵の「全体の進行役」。仕様書 002。
-- やることは、天敵を出す(spawn)・動きのループを1つ回す・やり直しに対応する、だけ。
-- 具体的な中身は Enemy フォルダの部品が担当する(くわしくは docs/design/enemy-architecture.md):
--   Perception(見る・捕まえる判定)、Movement(歩く)、Behaviors(行動)、Definitions(天敵の種類)。
-- 動きと捕獲の判定は、すべてサーバーで行う。

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local FieldService = require(script.Parent.FieldService)
local RoundService = require(script.Parent.RoundService)
local Types = require(script.Parent.Enemy.Types)
local Perception = require(script.Parent.Enemy.Perception)
local WarnOnce = require(script.Parent.Enemy.WarnOnce)
local Movement = require(script.Parent.Enemy.Movement)
local Farmer = require(script.Parent.Enemy.Definitions.Farmer)
local Harvester = require(script.Parent.Enemy.Definitions.Harvester)

-- ===== 天敵の種類の一覧 =====
-- 新しい種類(サギなど)は、Enemy/Definitions にファイルを作って、ここに足すだけ。
local definitions: { Types.Definition } = {
	Farmer,
	Harvester, -- 出番(IsActive)になるまで作らない
}

-- 天敵1体ぶんの「置き場」。作り直しても、置き場は同じものを使う
type Slot = {
	Definition: Types.Definition,
	SpawnIndex: number, -- 出現位置にした見回り地点の番号
	Ctx: Types.Context?, -- いまの天敵の状態(まだ作れていなければ nil)
	Spawning: boolean, -- 作っている最中か(二重に作らないための印)
	Epoch: number, -- 消すたびに増やす番号。作っている間に消されたら、番号が変わるので、作るのをやめる
	Finished: boolean, -- 出番の途中で、動きが最後まで終わった印(IsActive がある種類用。出番が終わるまで作り直さない)
}

local EnemyService = {}

local slots: { Slot } = {} -- 天敵ごとの状態の表
local patrolPoints: { Vector3 } = {}
local started = false
-- 動きのループの番号。新しいループを始めるたびに増やし、古いループは自分で終わる
local loopToken = 0
local loopRunning = false -- いま動きのループが動いているか

-- ===== 行動の切り替え =====

-- 行動を切り替える。いまの行動の Exit → 新しい行動の Enter の順に呼ぶ。
-- 同じ名前への切り替えも、やり直しとして行う
local function switchBehavior(ctx: Types.Context, name: string)
	local definition = ctx.Definition
	local nextName = name
	local nextBehavior = definition.Behaviors[nextName]
	if not nextBehavior then
		WarnOnce.Warn(
			`behavior:{definition.Name}:{name}`,
			`[EnemyService] 行動 {name} が {definition.Name} にありません。最初の行動に戻します`
		)
		nextName = definition.InitialBehavior
		nextBehavior = definition.Behaviors[nextName]
		if not nextBehavior then
			return
		end
	end
	local current = definition.Behaviors[ctx.BehaviorName]
	if current then
		current.Exit(ctx)
	end
	ctx.BehaviorName = nextName
	ctx.SwitchCount += 1
	nextBehavior.Enter(ctx)
end

-- ===== 天敵を作る =====

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

-- 最初の出現位置の番号:見回り地点のうち、スタート地点(南端)からいちばん遠いもの
local function findFarthestPatrolIndex(): number
	local startPosition = Vector3.new(0, 0, Config.FieldSize / 2 - Config.SpawnEdgeOffset)
	local farthest = 0
	local farthestIndex = 1
	for index, point in patrolPoints do
		local distance = Perception.FlatDistance(point, startPosition)
		if distance > farthest then
			farthest = distance
			farthestIndex = index
		end
	end
	return farthestIndex
end

local function newContext(
	definition: Types.Definition,
	model: Model,
	humanoid: Humanoid?,
	root: BasePart,
	spawnPoint: Vector3
): Types.Context
	return {
		Definition = definition,
		Model = model,
		Humanoid = humanoid,
		Root = root,
		SpawnPoint = spawnPoint,
		PatrolPoints = patrolPoints,
		PatrolIndex = 1,
		BehaviorName = "",
		SwitchCount = 0,
		LastTickAt = os.clock(),
		Finished = false,
		Target = nil,
		AnyPlaying = false,
		ChasePlayer = nil,
		LastSeenPosition = nil,
		LostSightSince = nil,
		SearchEndAt = 0,
		Move = Movement.NewState(),
	}
end

-- 天敵1体を片づける:いまの行動の Exit(接続やタイマーの片づけ)→経路の記憶を捨てる→モデルを消す
local function destroyContext(ctx: Types.Context)
	local behavior = ctx.Definition.Behaviors[ctx.BehaviorName]
	if behavior then
		local ok, err = pcall(behavior.Exit, ctx)
		if not ok then
			WarnOnce.Warn(`exit:{ctx.Definition.Name}:{tostring(err)}`, `[EnemyService] 行動の Exit でエラー: {err}`)
		end
	end
	Movement.Clear(ctx) -- 計算中の古い経路の結果を捨てさせる
	ctx.Model:Destroy()
end

-- 古い天敵が残っていたら片づける
local function removeOld(slot: Slot)
	local old = slot.Ctx
	slot.Ctx = nil
	if old then
		destroyContext(old)
	end
end

-- 出番が終わった天敵を消す(IsActive がある種類用)。作っている最中なら、作るのをやめさせる
local function despawn(slot: Slot)
	slot.Epoch += 1
	removeOld(slot)
end

-- 体の部品を探す。定義が FindBody を持っていればそれで(Humanoid なしでもよい)、なければ人型を探す。
-- root が nil なら、作れていない
local function findBody(definition: Types.Definition, model: Model): (Humanoid?, BasePart?)
	local custom = definition.FindBody
	if custom then
		return custom(model)
	end
	return Perception.FindBody(model)
end

-- 天敵を作って、置き場に入れる。失敗したら error を投げる(呼ぶ側が pcall で包む)。
-- 作っている間に消されたら(番号が変わったら)、作ったモデルを捨てて false を返す。
-- 人型の作成は待ちが入る
local function buildEnemy(slot: Slot): boolean
	local definition = slot.Definition
	local epoch = slot.Epoch
	local model = definition.Create()
	if slot.Epoch ~= epoch then
		model:Destroy()
		return false
	end
	removeOld(slot)

	local point = patrolPoints[slot.SpawnIndex]
	definition.PlaceAt(model, point) -- まず、Workspace に入れる前に置く(足元の高さを補正する)
	model.Parent = getEnemiesFolder()
	definition.OnPlaced(model) -- Workspace に入れたあとで、動きの計算をサーバーにする、など
	task.wait() -- 1フレーム待ってから、Workspace に入った状態の足元の高さで、もう一度補正する
	if slot.Epoch ~= epoch then
		model:Destroy()
		return false
	end
	if model.Parent == nil then
		error("待っている間にモデルが消えました")
	end
	definition.PlaceAt(model, point)

	local humanoid, root = findBody(definition, model)
	if not root then
		model:Destroy()
		error("体の部品(HumanoidRootPart など)が足りません")
	end
	local ctx = newContext(definition, model, humanoid, root, point)
	slot.Ctx = ctx
	switchBehavior(ctx, definition.InitialBehavior)
	return true
end

-- 天敵を作る。成功したら true。作っている最中なら何もしない
local function spawnEnemy(slot: Slot): boolean
	if slot.Spawning then
		return false
	end
	slot.Spawning = true
	local ok, result = pcall(buildEnemy, slot)
	slot.Spawning = false
	if not ok then
		local err = result
		WarnOnce.Warn(
			`spawn:{slot.Definition.Name}:{tostring(err)}`,
			`[EnemyService] {slot.Definition.Name} を作れませんでした: {err}`
		)
		return false
	end
	return result == true
end

-- ===== 判断のループ =====

-- 天敵1体の、判断1回ぶん。体が使えなくなっていたら false。
-- 順番: 捕獲の判定 → 見回す → 行動の Update → 行動の切り替え
local function tickEnemy(slot: Slot, ctx: Types.Context): boolean
	if not Perception.IsUsable(ctx) then
		return false
	end
	local now = os.clock()
	local dt = now - ctx.LastTickAt
	ctx.LastTickAt = now

	-- どの行動の最中でも、近すぎる相手は捕まえる(潜っていても、ごく近くなら捕まる)
	if Perception.CheckCatch(ctx) then
		-- 捕まえたら最初の行動(見回り)に戻る。ただし、戻さない定義(稲刈り機)は、そのまま続ける
		if ctx.Definition.ResetOnCatch ~= false then
			Movement.Stop(ctx)
			switchBehavior(ctx, ctx.Definition.InitialBehavior)
		end
		return true
	end

	if not ctx.Definition.SkipScan then
		Perception.Scan(ctx)
	end
	local behavior = ctx.Definition.Behaviors[ctx.BehaviorName]
	if not behavior then
		switchBehavior(ctx, ctx.Definition.InitialBehavior)
		return true
	end
	local switchCountBefore = ctx.SwitchCount
	local nextName = behavior.Update(ctx, dt) -- 経路を待つ間、止まることがある
	-- 待っている間に、やり直しなどで別の天敵・別の行動に変わっていたら、切り替えない
	if nextName ~= nil and slot.Ctx == ctx and ctx.SwitchCount == switchCountBefore and Perception.IsUsable(ctx) then
		switchBehavior(ctx, nextName)
	end
	return true
end

-- 出番がある種類(IsActive を持つ)の、判断1回ぶん。
-- 出番でなければ、モデルを消して(あれば)何もしない。出番なら、なければ作り、あれば動きの判断をする。
-- 動きが最後まで終わったら、モデルを消して、出番が終わるまで作り直さない
local function updateGatedSlot(slot: Slot, isActive: () -> boolean)
	if not isActive() then
		slot.Finished = false -- 次の出番では、また出られる
		if slot.Ctx ~= nil or slot.Spawning then
			despawn(slot)
		end
		return
	end
	if slot.Finished then
		return
	end
	local ctx = slot.Ctx
	if ctx == nil then
		spawnEnemy(slot)
		return
	end
	if not tickEnemy(slot, ctx) then
		despawn(slot) -- 体が使えなくなった:消して、次の判断で作り直す
		return
	end
	if ctx.Finished and slot.Ctx == ctx then
		despawn(slot)
		slot.Finished = true
	end
end

-- 判断1回ぶん(全員)。使える天敵が1体もいなくなったら false(ループを終える)。
-- 出番がある種類は、いまいなくても、あとで出るかもしれないので、ループを続ける
local function think(): boolean
	local anyUsable = false
	for _, slot in slots do
		local isActive = slot.Definition.IsActive
		if isActive then
			local ok, err = pcall(updateGatedSlot, slot, isActive)
			if not ok then
				WarnOnce.Warn(`think:{tostring(err)}`, `[EnemyService] 判断中にエラー: {err}`)
			end
			anyUsable = true
		else
			local ctx = slot.Ctx
			if ctx then
				local ok, usable = pcall(tickEnemy, slot, ctx)
				if not ok then
					WarnOnce.Warn(`think:{tostring(usable)}`, `[EnemyService] 判断中にエラー: {usable}`)
					anyUsable = true -- エラーでも、次の判断で続ける
				elseif usable == true then
					anyUsable = true
				end
			end
		end
	end
	return anyUsable
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
			if not think() then
				reason = "天敵が壊れた・倒れた・いなくなった"
				break
			end
		end
		warn(`[EnemyService] 動きのループを終えます: {reason}`)
		if myToken == loopToken then
			loopRunning = false -- 引き継がれたときは、新しいループの印を消さない
		end
	end)
end

-- ===== やり直し =====

-- 置き場1つぶんのやり直し。
-- 天敵が壊れている・死んでいるなら作り直す。無事なら、出現位置に戻して最初の行動に戻す。
-- 作り直したら true
local function restartSlot(slot: Slot): boolean
	if slot.Definition.IsActive then
		-- 出番がある種類(稲刈り機):モデルを消して、次の出番まで出さない
		despawn(slot)
		slot.Finished = false
		return false
	end
	local ctx = slot.Ctx
	if not ctx or not Perception.IsUsable(ctx) then
		if slot.Spawning then
			return false -- すでに作り直している最中
		end
		warn(`[EnemyService] {slot.Definition.Name} が使えないので、作り直します`)
		return spawnEnemy(slot)
	end
	ctx.Definition.PlaceAt(ctx.Model, ctx.SpawnPoint) -- 横位置を戻し、足元の高さも補正し直す
	switchBehavior(ctx, ctx.Definition.InitialBehavior)
	Movement.Stop(ctx)
	return false
end

-- 使える天敵が1体でもいるか
local function hasUsableEnemy(): boolean
	for _, slot in slots do
		local ctx = slot.Ctx
		if ctx and Perception.IsUsable(ctx) then
			return true
		end
	end
	return false
end

-- 出番がある種類が1つでもあるか(あれば、モデルがなくても、ループを動かしておく)
local function hasGatedSlot(): boolean
	for _, slot in slots do
		if slot.Definition.IsActive then
			return true
		end
	end
	return false
end

-- 「もう一度」でやり直すとき(RoundService から呼ばれる)
local function onRestart()
	for _, slot in slots do
		restartSlot(slot)
	end
	if not loopRunning and (hasUsableEnemy() or hasGatedSlot()) then
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
		warn("[EnemyService] 見回り地点がないので、天敵を出せません")
		return
	end

	-- 種類ごとに置き場を作る。出現位置は、いちばん遠い地点から順にずらす
	local firstIndex = findFarthestPatrolIndex()
	for order, definition in definitions do
		table.insert(slots, {
			Definition = definition,
			SpawnIndex = (firstIndex + order - 2) % #patrolPoints + 1,
			Ctx = nil,
			Spawning = false,
			Epoch = 0,
			Finished = false,
		})
	end

	-- 最初に作れなくても、「もう一度」のときに作り直せるように、先に登録しておく
	RoundService.OnRestart(onRestart)

	local anySpawned = false
	for _, slot in slots do
		-- 出番がある種類(稲刈り機)は、ここでは作らない。出番になったら、判断のループが作る
		if slot.Definition.IsActive == nil and spawnEnemy(slot) then
			anySpawned = true
		end
	end
	if anySpawned or hasGatedSlot() then
		startLoop()
	else
		warn("[EnemyService] 最初の天敵を作れませんでした。「もう一度」で作り直します")
	end
end

return EnemyService
