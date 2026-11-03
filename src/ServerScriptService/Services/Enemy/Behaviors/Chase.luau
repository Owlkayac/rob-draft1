--!strict
-- 行動「追跡」: 見えた相手の位置へ、障害物をよけて歩く。
-- 見えなくなったら、最後に見えた位置へ向かう。潜られたら、その場所で「Search」(探す)に切り替え(Search を持たない天敵は「Patrol」)、
-- 見失って時間がたったら「Patrol」(見回り)に戻る。
-- 捕まえる判定は、行動の中ではなく、EnemyService が毎回の最初に行う。

local Types = require(script.Parent.Parent.Types)
local Stats = require(script.Parent.Parent.Stats)
local Perception = require(script.Parent.Parent.Perception)
local Movement = require(script.Parent.Parent.Movement)
local CrayfishService = require(script.Parent.Parent.Parent.CrayfishService)

-- ctx.Target は「Chase に切り替える判断をしたときの、見えた相手」
local function enter(ctx: Types.Context)
	local target = ctx.Target
	local player = if target then target.Player else nil
	ctx.Humanoid.WalkSpeed = Stats.Get(ctx.Definition, "ChaseSpeed", player)
	ctx.ChasePlayer = player
	ctx.LastSeenPosition = if target then target.Position else nil
	ctx.LostSightSince = nil
	Movement.Clear(ctx)
end

-- 見えなくなっているときの追跡(潜った・遠くへ離れた・いなくなった)
local function updateLost(ctx: Types.Context): string?
	local now = os.clock()
	local since = ctx.LostSightSince or now -- 見えなくなった最初の判断なら、いまの時刻
	ctx.LostSightSince = since
	local lastSeen = ctx.LastSeenPosition
	local loseSeconds = Stats.Get(ctx.Definition, "LoseSightSeconds", nil)
	if lastSeen == nil or now - since >= loseSeconds then
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
	if arrived then
		Movement.Stop(ctx)
		return nil
	end
	Movement.WalkTo(ctx, lastSeen)
	return nil
end

local function update(ctx: Types.Context, _dt: number): string?
	local target = ctx.Target
	if not target then
		return updateLost(ctx)
	end
	ctx.ChasePlayer = target.Player
	ctx.LastSeenPosition = target.Position
	ctx.LostSightSince = nil
	Movement.WalkTo(ctx, target.Position)
	return nil
end

local function exit(_ctx: Types.Context)
	-- 追跡をやめるときに片づけることは、いまはない(次の行動の Enter が記憶を整える)
end

local Chase: Types.Behavior = {
	Enter = enter,
	Update = update,
	Exit = exit,
}

return Chase
