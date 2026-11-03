--!strict
-- 行動「探す」: 潜られた場所で、その場に立って少し探す。
-- 探している間に見つけたら「Chase」(追跡)、時間が来たら「Patrol」(見回り)に切り替える。

local Types = require(script.Parent.Parent.Types)
local Stats = require(script.Parent.Parent.Stats)
local Movement = require(script.Parent.Parent.Movement)

local function enter(ctx: Types.Context)
	local humanoid = ctx.Humanoid
	if humanoid then
		humanoid.WalkSpeed = Stats.Get(ctx.Definition, "WalkSpeed", nil)
	end
	ctx.SearchEndAt = os.clock() + Stats.Get(ctx.Definition, "SearchSeconds", nil)
	ctx.LostSightSince = nil
	Movement.Clear(ctx)
	Movement.Stop(ctx) -- 歩き回らず、その場で探す
end

local function update(ctx: Types.Context, _dt: number): string?
	if ctx.Target then
		return "Chase" -- 探している間に見つけた
	end
	if os.clock() >= ctx.SearchEndAt then
		return "Patrol"
	end
	Movement.Stop(ctx)
	return nil
end

local function exit(_ctx: Types.Context)
	-- 探すのをやめるときに片づけることは、いまはない
end

local Search: Types.Behavior = {
	Enter = enter,
	Update = update,
	Exit = exit,
}

return Search
