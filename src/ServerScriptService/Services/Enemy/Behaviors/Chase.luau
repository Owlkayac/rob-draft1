--!strict
-- 行動「追跡」: 見えた相手の位置へ、障害物をよけて歩く。(仕様書 002、014 の 1-2)
-- 見えなくなったら、最後に見えた位置へ向かう。潜られたら、その場所で「Search」(探す)に切り替え(Search を持たない天敵は「Patrol」)、
-- 見失って時間がたったら「Patrol」(見回り)に戻る。遊んでいる人が1人もいなくなったら(ctx.AnyPlaying が false)、すぐ「Patrol」に戻る。
-- 捕まえる判定は、行動の中ではなく、EnemyService が毎回の最初に行う。
--
-- ランダムな動き(仕様書 014):
--   ・ダッシュ:ランダムな間隔(BurstInterval)で、BurstSeconds だけ、速さが BurstMultiplier 倍になる。
--   ・つまずき:ランダムな間隔(StumbleInterval)で、StumbleSeconds だけ、足が止まる。
--   ・速さの上限:ChaseSpeedMax(ザリガニの歩く速さ × 1.05)を超えない。ダッシュしても超えない(公平さ)。
--   ・見失うまでの時間:追跡に入るたびに、LoseSightSecondsMin 〜 Max から決める。
-- ダッシュとつまずきは、その数字(BurstSeconds・StumbleSeconds)を持つ天敵だけが行う。
-- 時間の判定は、判断の間隔(Config.EnemyTickSeconds = 0.2秒)ごとに見るので、実際の長さは最大でその分だけ長くなる。

local Types = require(script.Parent.Parent.Types)
local Stats = require(script.Parent.Parent.Stats)
local Perception = require(script.Parent.Parent.Perception)
local Movement = require(script.Parent.Parent.Movement)
local EnemyRandom = require(script.Parent.Parent.EnemyRandom)
local CrayfishService = require(script.Parent.Parent.Parent.CrayfishService)

-- 天敵1体ぶんの、追跡の記憶(Exit で消す)
type ChaseState = {
	LoseSightSeconds: number, -- この追跡で、見失ってから見回りに戻るまでの時間(秒)
	BurstEnabled: boolean, -- ダッシュをするか
	NextBurstAt: number, -- 次のダッシュを始める時刻(os.clock)
	BurstUntil: number, -- ダッシュを終える時刻(os.clock)。ダッシュ中でなければ過去の時刻
	StumbleEnabled: boolean, -- つまずくか
	NextStumbleAt: number, -- 次につまずく時刻(os.clock)
	StumbleUntil: number, -- つまずきを終える時刻(os.clock)
}

local states: { [Types.Context]: ChaseState } = {}

local function newState(ctx: Types.Context): ChaseState
	local now = os.clock()
	local burstEnabled = EnemyRandom.HasStat(ctx, "BurstSeconds")
	local stumbleEnabled = EnemyRandom.HasStat(ctx, "StumbleSeconds")
	return {
		LoseSightSeconds = EnemyRandom.Seconds(ctx, "LoseSightSecondsMin", "LoseSightSecondsMax"),
		BurstEnabled = burstEnabled,
		NextBurstAt = if burstEnabled then now + EnemyRandom.Seconds(ctx, "BurstIntervalMin", "BurstIntervalMax") else math.huge,
		BurstUntil = 0,
		StumbleEnabled = stumbleEnabled,
		NextStumbleAt = if stumbleEnabled
			then now + EnemyRandom.Seconds(ctx, "StumbleIntervalMin", "StumbleIntervalMax")
			else math.huge,
		StumbleUntil = 0,
	}
end

local function getState(ctx: Types.Context): ChaseState
	local state = states[ctx]
	if state == nil then
		state = newState(ctx)
		states[ctx] = state
	end
	return state
end

-- つまずきの時間が来ていれば、つまずき始める(次のつまずきの時刻も決める)
local function updateStumble(ctx: Types.Context, state: ChaseState, now: number)
	if not state.StumbleEnabled or now < state.NextStumbleAt or now < state.StumbleUntil then
		return
	end
	state.StumbleUntil = now + EnemyRandom.FixedSeconds(ctx, "StumbleSeconds")
	state.NextStumbleAt = state.StumbleUntil + EnemyRandom.Seconds(ctx, "StumbleIntervalMin", "StumbleIntervalMax")
end

-- ダッシュの時間が来ていれば、ダッシュを始める(次のダッシュの時刻も決める)
local function updateBurst(ctx: Types.Context, state: ChaseState, now: number)
	if not state.BurstEnabled or now < state.NextBurstAt or now < state.BurstUntil then
		return
	end
	state.BurstUntil = now + EnemyRandom.FixedSeconds(ctx, "BurstSeconds")
	state.NextBurstAt = state.BurstUntil + EnemyRandom.Seconds(ctx, "BurstIntervalMin", "BurstIntervalMax")
end

-- 通常の追跡の速さ(つまずき・ダッシュのない値)。上限(ChaseSpeedMax)を超えない
local function baseChaseSpeed(ctx: Types.Context, player: Player?): number
	local speed = Stats.Get(ctx.Definition, "ChaseSpeed", player)
	if EnemyRandom.HasStat(ctx, "ChaseSpeedMax") then
		speed = math.min(speed, Stats.Get(ctx.Definition, "ChaseSpeedMax", player))
	end
	return speed
end

-- いまの追跡の速さ。つまずき中は 0。ダッシュ中は倍率がかかる。ただし、上限(ChaseSpeedMax)を超えない
local function currentSpeed(ctx: Types.Context, state: ChaseState, player: Player?, now: number): number
	updateStumble(ctx, state, now)
	if now < state.StumbleUntil then
		return 0
	end
	updateBurst(ctx, state, now)
	local speed = Stats.Get(ctx.Definition, "ChaseSpeed", player)
	if now < state.BurstUntil then
		speed *= Stats.Get(ctx.Definition, "BurstMultiplier", player)
	end
	if EnemyRandom.HasStat(ctx, "ChaseSpeedMax") then
		speed = math.min(speed, Stats.Get(ctx.Definition, "ChaseSpeedMax", player))
	end
	return speed
end

-- いまの速さを Humanoid に入れる。つまずき中(足が止まっている間)は true を返す
local function applySpeed(ctx: Types.Context, state: ChaseState, player: Player?): boolean
	local now = os.clock()
	local speed = currentSpeed(ctx, state, player, now)
	local humanoid = ctx.Humanoid
	if humanoid and humanoid.WalkSpeed ~= speed then
		humanoid.WalkSpeed = speed
	end
	return now < state.StumbleUntil
end

-- ctx.Target は「Chase に切り替える判断をしたときの、見えた相手」
local function enter(ctx: Types.Context)
	local target = ctx.Target
	local player = if target then target.Player else nil
	local state = newState(ctx)
	states[ctx] = state
	applySpeed(ctx, state, player)
	ctx.ChasePlayer = player
	ctx.LastSeenPosition = if target then target.Position else nil
	ctx.LostSightSince = nil
	Movement.Clear(ctx)
end

-- 見えなくなっているときの追跡(潜った・遠くへ離れた・いなくなった)
local function updateLost(ctx: Types.Context, state: ChaseState, stumbling: boolean): string?
	local now = os.clock()
	local since = ctx.LostSightSince or now -- 見えなくなった最初の判断なら、いまの時刻
	ctx.LostSightSince = since
	local lastSeen = ctx.LastSeenPosition
	if lastSeen == nil or now - since >= state.LoseSightSeconds then
		return "Patrol"
	end
	local arriveDistance = Stats.Get(ctx.Definition, "PatrolArriveDistance", nil)
	local arrived = Perception.FlatDistance(ctx.Root.Position, lastSeen) <= arriveDistance
	local diver = ctx.ChasePlayer
	if diver and CrayfishService.IsHidden(diver) and arrived then
		-- 潜った場所に着いた。「探す」行動を持つ天敵なら探し、持たない天敵は見回りに戻る
		if ctx.Definition.Behaviors["Search"] ~= nil then
			return "Search"
		end
		return "Patrol"
	end
	if arrived or stumbling then
		Movement.Stop(ctx)
		return nil
	end
	Movement.WalkTo(ctx, lastSeen)
	return nil
end

local function update(ctx: Types.Context, _dt: number): string?
	if not ctx.AnyPlaying then
		return "Patrol" -- 遊んでいる人が1人もいない(クリア・捕まった、など)。追跡をやめる(Patrol の Enter が速さを入れ直す)
	end
	local state = getState(ctx)
	local target = ctx.Target
	local stumbling = applySpeed(ctx, state, if target then target.Player else ctx.ChasePlayer)
	if not target then
		return updateLost(ctx, state, stumbling)
	end
	ctx.ChasePlayer = target.Player
	ctx.LastSeenPosition = target.Position
	ctx.LostSightSince = nil
	if stumbling then
		Movement.Stop(ctx) -- つまずいて、足が止まっている
		return nil
	end
	Movement.WalkTo(ctx, target.Position)
	return nil
end

local function exit(ctx: Types.Context)
	states[ctx] = nil -- 追跡の記憶を捨てる。つまずき・ダッシュの状態もここで解除される(次の行動の Enter が、ほかの記憶を整える)
	local humanoid = ctx.Humanoid
	if humanoid and humanoid.Parent ~= nil then
		humanoid.WalkSpeed = baseChaseSpeed(ctx, ctx.ChasePlayer) -- つまずきで 0 のまま残らないよう、通常の追跡の速さに戻す
	end
end

local Chase: Types.Behavior = {
	Enter = enter,
	Update = update,
	Exit = exit,
}

return Chase
