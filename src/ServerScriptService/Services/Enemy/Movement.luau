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

-- ===== 向きを変える(仕様書 014。立ち止まったまま、相手のほうを向く・きょろきょろする) =====
-- 向き(yaw)は、真上から見て、どちらを向いているかの角度(ラジアン)。
-- CFrame.Angles(0, yaw, 0) の正面(-Z)は、(-sin yaw, 0, -cos yaw) の向き。逆算すると yaw = atan2(-x, -z)。

-- 向きの角度の計算に使う、ごく小さい数(これより短いベクトルは「向きなし」とみなす)
local TINY = 1e-3

-- direction の向き(横方向だけ)を、yaw に直す。ほぼ真上・真下で、向きが決まらないときは nil
function Movement.YawOfDirection(direction: Vector3): number?
	local x = direction.X
	local z = direction.Z
	if math.sqrt(x * x + z * z) < TINY then
		return nil
	end
	return math.atan2(-x, -z)
end

-- いまの向き(yaw)
function Movement.GetYaw(ctx: Types.Context): number
	local look = ctx.Root.CFrame.LookVector
	return Movement.YawOfDirection(look) or 0
end

-- yaw の差を -pi 〜 pi にそろえる(いちばん近い回り方にするため)
local function wrapAngle(angle: number): number
	return (angle + math.pi) % (2 * math.pi) - math.pi
end

-- いまの向きから、targetYaw に向かって、最大 maxStep(ラジアン)だけ回す。位置は変えない。
-- 立ち止まっているとき(Humanoid が自分では向きを変えないとき)に使う。
-- Humanoid を使う天敵の Root(HumanoidRootPart)の CFrame を、向きだけ変えて入れ直す
function Movement.TurnToYaw(ctx: Types.Context, targetYaw: number, maxStep: number)
	local root = ctx.Root
	if root.Parent == nil then
		return
	end
	local current = Movement.GetYaw(ctx)
	local limit = math.max(maxStep, 0)
	local step = math.clamp(wrapAngle(targetYaw - current), -limit, limit)
	if math.abs(step) < TINY then
		return
	end
	root.CFrame = CFrame.new(root.Position) * CFrame.Angles(0, current + step, 0)
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
