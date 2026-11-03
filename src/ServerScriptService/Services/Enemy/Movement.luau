--!strict
-- 天敵の「歩く」ための部品。経路探索(障害物をよけて目的地へ向かう仕組み)を使う。
-- 経路は EnemyRepathSeconds ごとに作り直す。作れなければ、目的地へ直接向かう。
-- 経路を待っている間に状況が変わったら、古い結果は捨てる(世代番号で見分ける)。

local PathfindingService = game:GetService("PathfindingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Types = require(script.Parent.Types)
local Stats = require(script.Parent.Stats)
local Perception = require(script.Parent.Perception)

local Movement = {}

-- 経路の記憶の、最初の状態
function Movement.NewState(): Types.MoveState
	return {
		Waypoints = {},
		WaypointIndex = 1,
		LastPathAt = -math.huge,
		Generation = 0,
	}
end

-- 経路の記憶を消す(次の移動で作り直す)。世代番号も進めるので、計算中の古い結果は捨てられる
function Movement.Clear(ctx: Types.Context)
	local move = ctx.Move
	move.Generation += 1
	move.Waypoints = {}
	move.WaypointIndex = 1
	move.LastPathAt = -math.huge
end

-- その場で止まる
function Movement.Stop(ctx: Types.Context)
	local humanoid = ctx.Humanoid
	if humanoid then -- Humanoid を使わない天敵(稲刈り機)では、何もしない
		humanoid:MoveTo(ctx.Root.Position)
	end
end

-- 経路を作り直す。待っている間に世代が変わったり壊れたりして、結果を捨てたら false
local function refreshRoute(ctx: Types.Context, destination: Vector3): boolean
	local move = ctx.Move
	move.LastPathAt = os.clock()
	local myGeneration = move.Generation
	local path = PathfindingService:CreatePath({
		AgentRadius = Stats.Get(ctx.Definition, "AgentRadius", nil),
		AgentHeight = Stats.Get(ctx.Definition, "AgentHeight", nil),
		AgentCanJump = false,
	})
	-- 経路の始点は、根っこの中心ではなく、足元の高さ(モデルを囲む箱の底)にする
	local rootPosition = ctx.Root.Position
	local footY = ctx.Definition.GetFootY(ctx.Model)
	local start = Vector3.new(rootPosition.X, footY, rootPosition.Z)
	local ok = pcall(function()
		path:ComputeAsync(start, destination)
	end)
	-- 待っている間に、やり直しや行動の切り替え・破壊があったら、結果を捨てる
	if myGeneration ~= move.Generation or not ctx.Root.Parent then
		return false
	end
	if ok and path.Status == Enum.PathStatus.Success then
		move.Waypoints = path:GetWaypoints()
	else
		move.Waypoints = {} -- 経路が作れなかった:直接向かう
	end
	move.WaypointIndex = 1
	return true
end

-- 目的地へ向かって歩く。この関数は、経路を作る間、止まる(待つ)ことがある
function Movement.WalkTo(ctx: Types.Context, destination: Vector3)
	local humanoid = ctx.Humanoid
	if not humanoid then
		return -- Humanoid を使わない天敵は、歩けない
	end
	local move = ctx.Move
	if os.clock() - move.LastPathAt >= Config.EnemyRepathSeconds then
		if not refreshRoute(ctx, destination) then
			return
		end
	end

	-- 着いた点は飛ばして、次の点へ向かう
	local reach = Stats.Get(ctx.Definition, "WaypointReachDistance", nil)
	local rootPosition = ctx.Root.Position
	local waypoints = move.Waypoints
	while move.WaypointIndex <= #waypoints
		and Perception.FlatDistance(rootPosition, waypoints[move.WaypointIndex].Position) <= reach do
		move.WaypointIndex += 1
	end
	if move.WaypointIndex <= #waypoints then
		humanoid:MoveTo(waypoints[move.WaypointIndex].Position)
	else
		humanoid:MoveTo(destination)
	end
end

return Movement
