--!strict
-- 行動「見回り」: 田んぼの中の決まった地点を、順番に歩いて回る。
-- 見える相手がいたら「Chase」(追跡)に切り替える。

local Types = require(script.Parent.Parent.Types)
local Stats = require(script.Parent.Parent.Stats)
local Perception = require(script.Parent.Parent.Perception)
local Movement = require(script.Parent.Parent.Movement)

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

local function enter(ctx: Types.Context)
	local humanoid = ctx.Humanoid
	if humanoid then
		humanoid.WalkSpeed = Stats.Get(ctx.Definition, "WalkSpeed", nil)
	end
	ctx.ChasePlayer = nil
	ctx.LastSeenPosition = nil
	ctx.LostSightSince = nil
	ctx.PatrolIndex = nearestPatrolIndex(ctx)
	Movement.Clear(ctx)
end

local function update(ctx: Types.Context, _dt: number): string?
	if ctx.Target then
		return "Chase"
	end
	if not ctx.AnyPlaying then
		Movement.Stop(ctx) -- 遊んでいる人がいない間は、その場で止まる
		return nil
	end
	local points = ctx.PatrolPoints
	local point = points[ctx.PatrolIndex]
	local arrive = Stats.Get(ctx.Definition, "PatrolArriveDistance", nil)
	if Perception.FlatDistance(ctx.Root.Position, point) <= arrive then
		ctx.PatrolIndex = ctx.PatrolIndex % #points + 1 -- 次の地点へ(順番に回る)
		Movement.Clear(ctx)
		point = points[ctx.PatrolIndex]
	end
	Movement.WalkTo(ctx, point)
	return nil
end

local function exit(_ctx: Types.Context)
	-- 見回りをやめるときに片づけることは、いまはない
end

local Patrol: Types.Behavior = {
	Enter = enter,
	Update = update,
	Exit = exit,
}

return Patrol
