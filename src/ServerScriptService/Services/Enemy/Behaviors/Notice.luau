--!strict
-- 行動「気づく」: プレイヤーを見つけたあと、すぐには走らず、立ち止まって相手のほうを向く。(仕様書 014 の 1-2 と 2)
--   ・時間は NoticeSecondsMin 〜 Max のランダム(0.4〜0.9秒)。これが、プレイヤーが逃げる最初の猶予になる。
--   ・その間に相手が見えなくなった(潜った、遠くへ離れた、など)なら「Search」(探す)へ。
--   ・時間が来て、まだ見えていれば「Chase」(追跡)へ。
-- 頭の上の「!」は、行動が切り替わったときに EnemyService が出す(Definition.OnBehaviorChanged)。
-- 捕まえる判定は、行動の中ではなく、EnemyService が毎回の最初に行うので、気づいている間も捕まえられる。

local Types = require(script.Parent.Parent.Types)
local Stats = require(script.Parent.Parent.Stats)
local Movement = require(script.Parent.Parent.Movement)
local EnemyRandom = require(script.Parent.Parent.EnemyRandom)

-- 天敵1体ぶんの記憶(Exit で消す)
type NoticeState = {
	EndAt: number, -- 気づくのを終える時刻(os.clock)
}

local states: { [Types.Context]: NoticeState } = {}

local function newState(ctx: Types.Context): NoticeState
	return {
		EndAt = os.clock() + EnemyRandom.Seconds(ctx, "NoticeSecondsMin", "NoticeSecondsMax"),
	}
end

-- 見えなくなったときの行き先:Search を持つ天敵は「探す」、持たない天敵は「見回り」
local function lostBehaviorName(ctx: Types.Context): string
	if ctx.Definition.Behaviors["Search"] ~= nil then
		return "Search"
	end
	return "Patrol"
end

-- ctx.Target は「Notice に切り替える判断をしたときの、見えた相手」
local function enter(ctx: Types.Context)
	local target = ctx.Target
	ctx.ChasePlayer = if target then target.Player else nil
	ctx.LastSeenPosition = if target then target.Position else nil
	ctx.LostSightSince = nil
	states[ctx] = newState(ctx)
	Movement.Clear(ctx)
	Movement.Stop(ctx) -- 立ち止まる
end

local function update(ctx: Types.Context, dt: number): string?
	local target = ctx.Target
	if not target then
		return lostBehaviorName(ctx) -- 気づいている間に、見えなくなった。最後に見えた位置(LastSeenPosition)の近くを探す
	end
	ctx.ChasePlayer = target.Player
	ctx.LastSeenPosition = target.Position

	-- 立ち止まったまま、相手のほうを向き続ける
	Movement.Stop(ctx)
	local yaw = Movement.YawOfDirection(target.Position - ctx.Root.Position)
	if yaw ~= nil then
		Movement.TurnToYaw(ctx, yaw, Stats.Get(ctx.Definition, "NoticeTurnRadPerSecond", nil) * dt)
	end

	local state = states[ctx]
	if state == nil then
		state = newState(ctx)
		states[ctx] = state
	end
	if os.clock() >= state.EndAt then
		return "Chase" -- まだ見えている:追いかける(Chase の Enter が、ctx.Target を相手にする)
	end
	return nil
end

local function exit(ctx: Types.Context)
	states[ctx] = nil
end

local Notice: Types.Behavior = {
	Enter = enter,
	Update = update,
	Exit = exit,
}

return Notice
