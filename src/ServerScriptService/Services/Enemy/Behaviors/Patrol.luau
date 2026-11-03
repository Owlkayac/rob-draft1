--!strict
-- 行動「見回り」: 田んぼの中を、ランダムに歩いて回る。(仕様書 002、014 の 1-1)
--   ・次の行き先:確率 RoamPointChance で「田んぼの中のランダムな点」、そうでなければ「見回り地点(直前の地点以外)」。
--   ・着いたとき、確率 PauseChance で立ち止まり、ゆっくり向きを変える(きょろきょろ)。
--   ・行き先に PatrolTargetTimeoutSeconds 以内に着かなければ、その行き先を捨てて選び直す(保険)。
--   ・歩く速さを、1回の移動ごとに ±WalkSpeedJitter でゆらす。
--   ・「勘」:HunchInterval ごとに、確率 HunchChance で、いちばん近いプレイヤーの「だいたいの位置」へ向かう。
--     見つけたことにはならない(発見の判定は Perception.Scan のまま)。
-- 見える相手がいたら「Notice」(気づく)に切り替える。Notice を持たない天敵は「Chase」(追跡)。
-- 数字は Stats.Get で取る。乱数は ctx.Random。

local Types = require(script.Parent.Parent.Types)
local Stats = require(script.Parent.Parent.Stats)
local Perception = require(script.Parent.Parent.Perception)
local Movement = require(script.Parent.Parent.Movement)
local EnemyRandom = require(script.Parent.Parent.EnemyRandom)

-- 天敵1体ぶんの、見回りの記憶(Exit で消す)
type PatrolState = {
	Destination: Vector3?, -- いまの行き先(まだ決めていなければ nil)
	DestinationSetAt: number, -- いまの行き先に向かい始めた時刻(os.clock)。着かないときの保険に使う
	LastPatrolIndex: number, -- 直前に行った見回り地点の番号(次は、これ以外から選ぶ)
	PauseUntil: number, -- 立ち止まるのを終える時刻(os.clock)。立ち止まっていなければ 0
	LookYaw: number, -- 立ち止まっている間に、向きたい角度(yaw)
	BaseYaw: number, -- 立ち止まり始めたときの向き(きょろきょろの基準)
	SecondLookAt: number, -- 2回めに向きを変える時刻(os.clock)。もう変えたなら math.huge
	NextHunchAt: number, -- 次に「勘」を働かせる時刻(os.clock)
}

local states: { [Types.Context]: PatrolState } = {}

-- いちばん近い見回り地点の番号
local function nearestPatrolIndex(ctx: Types.Context): number
	local bestIndex = 1
	local bestDistance = math.huge
	for index, point in ctx.PatrolPoints do
		local distance = Perception.FlatDistance(ctx.Root.Position, point)
		if distance < bestDistance then
			bestDistance = distance
			bestIndex = index
		end
	end
	return bestIndex
end

-- 見回りの記憶を新しく作る
local function newState(ctx: Types.Context): PatrolState
	return {
		Destination = nil,
		DestinationSetAt = 0,
		LastPatrolIndex = nearestPatrolIndex(ctx), -- いまいる場所の地点は、最初の行き先にしない
		PauseUntil = 0,
		LookYaw = 0,
		BaseYaw = 0,
		SecondLookAt = math.huge,
		NextHunchAt = os.clock() + EnemyRandom.Seconds(ctx, "HunchIntervalMin", "HunchIntervalMax"),
	}
end

-- 記憶を取り出す(なければ作る)
local function getState(ctx: Types.Context): PatrolState
	local state = states[ctx]
	if state == nil then
		state = newState(ctx)
		states[ctx] = state
	end
	return state
end

-- 次の行き先を選ぶ:ランダムな点か、直前以外の見回り地点
local function chooseDestination(ctx: Types.Context, state: PatrolState): Vector3
	local points = ctx.PatrolPoints
	if #points == 0 or EnemyRandom.Chance(ctx, "RoamPointChance") then
		return EnemyRandom.PointInField(ctx)
	end
	local candidates: { number } = {}
	for index = 1, #points do
		if index ~= state.LastPatrolIndex then
			table.insert(candidates, index)
		end
	end
	if #candidates == 0 then
		table.insert(candidates, 1) -- 地点が1つだけのとき
	end
	local index = candidates[ctx.Random:NextInteger(1, #candidates)]
	state.LastPatrolIndex = index
	ctx.PatrolIndex = index
	return points[index]
end

-- 行き先へ向かい始める:経路を作り直し、歩く速さをゆらす(1回の移動ごとに1回)
local function beginMove(ctx: Types.Context, state: PatrolState, destination: Vector3)
	state.Destination = destination
	state.DestinationSetAt = os.clock()
	Movement.Clear(ctx)
	local humanoid = ctx.Humanoid
	if humanoid then
		humanoid.WalkSpeed = Stats.Get(ctx.Definition, "WalkSpeed", nil) * EnemyRandom.Jitter(ctx, "WalkSpeedJitter")
	end
end

-- 「勘」:時間が来ていれば、確率で、いちばん近いプレイヤーのだいたいの位置を行き先にする
local function tryHunch(ctx: Types.Context, state: PatrolState, now: number)
	if now < state.NextHunchAt then
		return
	end
	state.NextHunchAt = now + EnemyRandom.Seconds(ctx, "HunchIntervalMin", "HunchIntervalMax")
	if not EnemyRandom.Chance(ctx, "HunchChance") then
		return
	end
	local nearest = Perception.FindNearestPlayingPosition(ctx.Root.Position)
	if nearest == nil then
		return
	end
	local radius = Stats.Get(ctx.Definition, "HunchErrorRadius", nil)
	beginMove(ctx, state, EnemyRandom.PointNear(ctx, nearest, radius))
end

-- ランダムな向き(いまの向きから ±LookAroundMaxRad)を決める
local function pickLookYaw(ctx: Types.Context, state: PatrolState): number
	local maxRad = math.max(Stats.Get(ctx.Definition, "LookAroundMaxRad", nil), 0)
	if maxRad <= 0 then
		return state.BaseYaw
	end
	return state.BaseYaw + ctx.Random:NextNumber(-maxRad, maxRad)
end

-- 行き先に、時間内に着かなかったか(壁や障害物で着けない、などの保険)。
-- 時間の数字(PatrolTargetTimeoutSeconds)を持たない天敵は、いつまでも待つ
local function isDestinationTimedOut(ctx: Types.Context, state: PatrolState, now: number): boolean
	if not EnemyRandom.HasStat(ctx, "PatrolTargetTimeoutSeconds") then
		return false
	end
	local limit = Stats.Get(ctx.Definition, "PatrolTargetTimeoutSeconds", nil)
	return now - state.DestinationSetAt > limit
end

-- 立ち止まり始める:時間を決め、止まって、最初に向く角度を決める。2回めは、時間の半分のところで変える
local function startPause(ctx: Types.Context, state: PatrolState, now: number)
	local seconds = EnemyRandom.Seconds(ctx, "PauseSecondsMin", "PauseSecondsMax")
	state.PauseUntil = now + seconds
	state.SecondLookAt = now + seconds / 2
	state.BaseYaw = Movement.GetYaw(ctx)
	state.LookYaw = pickLookYaw(ctx, state)
	Movement.Clear(ctx)
	Movement.Stop(ctx)
end

-- 立ち止まっている間:ゆっくり向きを変える(きょろきょろ)
local function lookAround(ctx: Types.Context, state: PatrolState, now: number, dt: number)
	if now >= state.SecondLookAt then
		state.SecondLookAt = math.huge
		state.LookYaw = pickLookYaw(ctx, state)
	end
	local turnRate = Stats.Get(ctx.Definition, "PauseTurnRadPerSecond", nil)
	Movement.TurnToYaw(ctx, state.LookYaw, turnRate * dt)
end

-- 見つけたときに切り替える行動の名前:Notice があれば Notice、なければ Chase
local function foundBehaviorName(ctx: Types.Context): string
	if ctx.Definition.Behaviors["Notice"] ~= nil then
		return "Notice"
	end
	return "Chase"
end

local function enter(ctx: Types.Context)
	local humanoid = ctx.Humanoid
	if humanoid then
		humanoid.WalkSpeed = Stats.Get(ctx.Definition, "WalkSpeed", nil)
	end
	ctx.ChasePlayer = nil
	ctx.LastSeenPosition = nil
	ctx.LostSightSince = nil
	local state = newState(ctx)
	states[ctx] = state
	ctx.PatrolIndex = state.LastPatrolIndex
	Movement.Clear(ctx)
end

local function update(ctx: Types.Context, dt: number): string?
	if ctx.Target then
		return foundBehaviorName(ctx)
	end
	if not ctx.AnyPlaying then
		Movement.Stop(ctx) -- 遊んでいる人がいない間は、その場で止まる
		return nil
	end
	local state = getState(ctx)
	local now = os.clock()
	if state.PauseUntil > now then
		lookAround(ctx, state, now, dt)
		return nil
	end

	-- 行き先に着いたか。着いたら、確率で立ち止まる
	local destination = state.Destination
	if destination ~= nil then
		local arrive = Stats.Get(ctx.Definition, "PatrolArriveDistance", nil)
		if Perception.FlatDistance(ctx.Root.Position, destination) <= arrive then
			state.Destination = nil
			if EnemyRandom.Chance(ctx, "PauseChance") then
				startPause(ctx, state, now)
				return nil
			end
		end
	end

	-- 着かないまま時間がたったら、その行き先を捨てて、新しく選び直す
	if state.Destination ~= nil and isDestinationTimedOut(ctx, state, now) then
		state.Destination = nil
	end

	tryHunch(ctx, state, now)
	local current = state.Destination
	if current == nil then
		current = chooseDestination(ctx, state)
		beginMove(ctx, state, current)
	end
	Movement.WalkTo(ctx, current)
	return nil
end

local function exit(ctx: Types.Context)
	states[ctx] = nil
end

local Patrol: Types.Behavior = {
	Enter = enter,
	Update = update,
	Exit = exit,
}

return Patrol
