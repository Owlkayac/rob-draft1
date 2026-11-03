--!strict
-- 天敵の「見る」ための部品。見える・見えない、いちばん近い相手、捕まえる判定をまとめる。
-- 判定はすべてサーバーで行う(潜っているかの状態も、サーバーが持っているものを使う)。

local Players = game:GetService("Players")

local Types = require(script.Parent.Types)
local Stats = require(script.Parent.Stats)
local CrayfishService = require(script.Parent.Parent.CrayfishService)
local RoundService = require(script.Parent.Parent.RoundService)

local Perception = {}

-- 横方向(XZ)だけの距離。高さの違いは無視する
function Perception.FlatDistance(a: Vector3, b: Vector3): number
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end
local flatDistance = Perception.FlatDistance

-- 天敵の体がまだ使えるか(壊れた・倒れた・いなくなったら false)
function Perception.IsUsable(ctx: Types.Context): boolean
	return ctx.Model.Parent ~= nil
		and ctx.Humanoid.Parent ~= nil
		and ctx.Humanoid.Health > 0
		and ctx.Root.Parent ~= nil
end

-- モデルから体の部品を取り出す。足りなければ nil(天敵を作るときに使う)
function Perception.FindBody(model: Model): (Humanoid?, BasePart?)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local root = model:FindFirstChild("HumanoidRootPart")
	if not humanoid or humanoid.Health <= 0 or not root or not root:IsA("BasePart") then
		return nil, nil
	end
	return humanoid, root
end

-- 生きているプレイヤーの HumanoidRootPart を返す(遊んでいない・倒れている人は nil)
local function getPlayingRoot(player: Player): BasePart?
	if not RoundService.IsPlaying(player) then
		return nil
	end
	local character = player.Character
	if not character then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or humanoid.Health <= 0 or not root or not root:IsA("BasePart") then
		return nil
	end
	return root
end

-- 見回して、結果を ctx.Target(いちばん近い、見える相手)と ctx.AnyPlaying に入れる。
-- 見える条件: 発見距離以内にいて、かつ、潜っていない
function Perception.Scan(ctx: Types.Context)
	local best: Types.Target? = nil
	local anyPlaying = false
	local from = ctx.Root.Position
	for _, player in Players:GetPlayers() do
		local root = getPlayingRoot(player)
		if root then
			anyPlaying = true
			local distance = flatDistance(from, root.Position)
			local sight = Stats.Get(ctx.Definition, "SightDistance", player)
			local visible = distance <= sight and not CrayfishService.IsHidden(player)
			if visible and (best == nil or distance < best.Distance) then
				best = { Player = player, Position = root.Position, Distance = distance }
			end
		end
	end
	ctx.Target = best
	ctx.AnyPlaying = anyPlaying
end

-- 捕まえる判定。遊んでいて生きているプレイヤーそれぞれについて、横方向の距離を測り、
-- 潜っていなければ CatchDistance 以下、潜っていれば CatchHiddenDistance 以下で捕まえる。
-- 1人でも捕まえたら true
function Perception.CheckCatch(ctx: Types.Context): boolean
	local caughtAny = false
	local from = ctx.Root.Position
	for _, player in Players:GetPlayers() do
		local root = getPlayingRoot(player)
		if root then
			local statName = if CrayfishService.IsHidden(player) then "CatchHiddenDistance" else "CatchDistance"
			local limit = Stats.Get(ctx.Definition, statName, player)
			if flatDistance(from, root.Position) <= limit then
				RoundService.NotifyCaught(player)
				caughtAny = true
			end
		end
	end
	return caughtAny
end

return Perception
