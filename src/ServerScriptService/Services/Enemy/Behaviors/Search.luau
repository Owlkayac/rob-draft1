--!strict
-- 行動「探す」: 最後に見えた位置の近くを、少し歩き回って探す。(仕様書 002、014 の 1-3)
--   ・探す時間は SearchSecondsMin 〜 Max のランダム。
--   ・探すあいだ、最後に見えた位置から半径 SearchRoamRadius の中の、1〜2か所(SearchRoamSpotsMin 〜 Max)を、ランダムに歩く。
--     全部の場所を回ったら、その場で立ち止まって探す。
--   ・時間が来たら「Patrol」(見回り)に戻る。
-- 探している間に見つけたら、「Notice」(気づく)に切り替える。Notice を持たない天敵は「Chase」(追跡)。

local Types = require(script.Parent.Parent.Types)
local Stats = require(script.Parent.Parent.Stats)
local Perception = require(script.Parent.Parent.Perception)
local Movement = require(script.Parent.Parent.Movement)
local EnemyRandom = require(script.Parent.Parent.EnemyRandom)

-- 天敵1体ぶんの記憶(Exit で消す)
type SearchState = {
	Spots: { Vector3 }, -- 歩き回る場所(順番に回る)
	SpotIndex: number, -- 次に向かう場所の番号。Spots の数より大きくなったら、全部回った
}

local states: { [Types.Context]: SearchState } = {}

-- 歩き回る場所を、ランダムな数(Min 〜 Max)だけ選ぶ。中心は、最後に見えた位置(なければ、いまいる場所)
local function pickSpots(ctx: Types.Context): { Vector3 }
	local center = ctx.LastSeenPosition or ctx.Root.Position
	local radius = Stats.Get(ctx.Definition, "SearchRoamRadius", nil)
	local minSpots = math.floor(Stats.Get(ctx.Definition, "SearchRoamSpotsMin", nil))
	local maxSpots = math.floor(Stats.Get(ctx.Definition, "SearchRoamSpotsMax", nil))
	if maxSpots < minSpots then
		minSpots, maxSpots = maxSpots, minSpots
	end
	minSpots = math.max(minSpots, 0)
	maxSpots = math.max(maxSpots, minSpots)
	local count = ctx.Random:NextInteger(minSpots, maxSpots)
	local spots: { Vector3 } = {}
	for _ = 1, count do
		table.insert(spots, EnemyRandom.PointNear(ctx, center, radius))
	end
	return spots
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
	ctx.SearchEndAt = os.clock() + EnemyRandom.Seconds(ctx, "SearchSecondsMin", "SearchSecondsMax")
	ctx.LostSightSince = nil
	states[ctx] = { Spots = pickSpots(ctx), SpotIndex = 1 }
	Movement.Clear(ctx)
	Movement.Stop(ctx) -- 歩き出すまでは、その場に立つ
end

local function update(ctx: Types.Context, _dt: number): string?
	if ctx.Target then
		return foundBehaviorName(ctx) -- 探している間に見つけた
	end
	if os.clock() >= ctx.SearchEndAt then
		return "Patrol"
	end
	local state = states[ctx]
	if state == nil then
		state = { Spots = pickSpots(ctx), SpotIndex = 1 }
		states[ctx] = state
	end
	local spot: Vector3? = state.Spots[state.SpotIndex]
	if spot == nil then
		Movement.Stop(ctx) -- 全部の場所を回った:その場で探す
		return nil
	end
	local arrive = Stats.Get(ctx.Definition, "PatrolArriveDistance", nil)
	if Perception.FlatDistance(ctx.Root.Position, spot) <= arrive then
		state.SpotIndex += 1 -- 着いた:次の場所へ(なければ、次の判断で立ち止まる)
		Movement.Clear(ctx)
		Movement.Stop(ctx)
		return nil
	end
	Movement.WalkTo(ctx, spot)
	return nil
end

local function exit(ctx: Types.Context)
	states[ctx] = nil
end

local Search: Types.Behavior = {
	Enter = enter,
	Update = update,
	Exit = exit,
}

return Search
