--!strict
-- 天敵の「ランダム」を扱う部品。(仕様書 014)
-- 天敵1体ごとに、自分だけの乱数(Random)を1つ持つ(ctx.Random)。
--   Config.EnemyRandomSeed が 0 以外なら、その数字で固定する(デバッグ用。毎回同じ動きになる)。
--   0 なら Random.new()(毎回ちがう)。
-- ここには、行動(Patrol・Notice・Chase・Search・Sweep)が使う小さな道具をまとめる:
--   時間・確率・ゆらぎ・ランダムな場所。数字は Stats.Get で取る(補正が効くように)。
-- 読み込むのは Config / Types / Stats / FieldService だけ(循環 require を作らない)。

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Types = require(script.Parent.Types)
local Stats = require(script.Parent.Stats)
local FieldService = require(script.Parent.Parent.FieldService)

local EnemyRandom = {}

-- 時間・間隔の下限(秒)。設定が 0 でも、0 で割ったり、止まらなくなったりしないための安全のしくみ
local MIN_SECONDS = 0.001
-- ゆらぎの倍率の下限。ゆらぎの設定が大きすぎても、速さが 0 や マイナスにならないための安全のしくみ
local MIN_FACTOR = 0.1

-- 天敵1体ぶんの乱数を作る。シードが 0 なら毎回ちがう、0 以外ならその値で固定
function EnemyRandom.New(): Random
	local seed = Config.EnemyRandomSeed
	if seed ~= 0 then
		return Random.new(seed)
	end
	return Random.new()
end

-- その数字(BaseStats)を、この天敵が持っているか。持たない天敵は、その機能を使わない
function EnemyRandom.HasStat(ctx: Types.Context, statName: string): boolean
	return ctx.Definition.BaseStats[statName] ~= nil
end

-- 秒数を1つ決める:minName 〜 maxName の間のランダム。0.001 秒より小さくならない。
-- min が max より大きく書かれていても、入れ替えて使う
function EnemyRandom.Seconds(ctx: Types.Context, minName: string, maxName: string): number
	local low = Stats.Get(ctx.Definition, minName, nil)
	local high = Stats.Get(ctx.Definition, maxName, nil)
	if high < low then
		low, high = high, low
	end
	if high <= low then
		return math.max(low, MIN_SECONDS)
	end
	return math.max(ctx.Random:NextNumber(low, high), MIN_SECONDS)
end

-- 決まった秒数(ランダムではない)。0.001 秒より小さくならない
function EnemyRandom.FixedSeconds(ctx: Types.Context, statName: string): number
	return math.max(Stats.Get(ctx.Definition, statName, nil), MIN_SECONDS)
end

-- 確率(0〜1)で true。statName は確率の数字の名前
function EnemyRandom.Chance(ctx: Types.Context, statName: string): boolean
	return ctx.Random:NextNumber() < Stats.Get(ctx.Definition, statName, nil)
end

-- ゆらぎの倍率を返す。statName が 0.12 なら、0.88〜1.12 のランダムな倍率
function EnemyRandom.Jitter(ctx: Types.Context, statName: string): number
	local amount = math.max(Stats.Get(ctx.Definition, statName, nil), 0)
	if amount <= 0 then
		return 1
	end
	return math.max(1 + ctx.Random:NextNumber(-amount, amount), MIN_FACTOR)
end

-- 田んぼの中に収まるように、点の横位置を直す。壁から RoamWallMargin 以上はなす。
-- 高さは、見回り地点と同じ(ゆかの上面 + PatrolPointHeight)にそろえる
function EnemyRandom.ClampToField(ctx: Types.Context, point: Vector3): Vector3
	local bounds = FieldService.GetFieldBounds()
	local margin = if EnemyRandom.HasStat(ctx, "RoamWallMargin") then Stats.Get(ctx.Definition, "RoamWallMargin", nil) else 0
	local halfX = math.max(bounds.Size.X / 2 - margin, 0)
	local halfZ = math.max(bounds.Size.Z / 2 - margin, 0)
	local x = math.clamp(point.X, bounds.Center.X - halfX, bounds.Center.X + halfX)
	local z = math.clamp(point.Z, bounds.Center.Z - halfZ, bounds.Center.Z + halfZ)
	return Vector3.new(x, bounds.Center.Y + Config.PatrolPointHeight, z)
end

-- 田んぼの中の、ランダムな点(壁から RoamWallMargin 以上はなれている)
function EnemyRandom.PointInField(ctx: Types.Context): Vector3
	-- いったん田んぼ全体の中で選び、壁に近すぎれば ClampToField が内側に寄せる
	local bounds = FieldService.GetFieldBounds()
	local halfX = bounds.Size.X / 2
	local halfZ = bounds.Size.Z / 2
	local x = ctx.Random:NextNumber(bounds.Center.X - halfX, bounds.Center.X + halfX)
	local z = ctx.Random:NextNumber(bounds.Center.Z - halfZ, bounds.Center.Z + halfZ)
	return EnemyRandom.ClampToField(ctx, Vector3.new(x, bounds.Center.Y, z))
end

-- center の近く(半径 radius の円の中)の、ランダムな点。田んぼの外に出たら、中に寄せる。
-- 平方根を使うのは、円の中で偏らず、まんべんなく選ぶため
function EnemyRandom.PointNear(ctx: Types.Context, center: Vector3, radius: number): Vector3
	local angle = ctx.Random:NextNumber(0, 2 * math.pi)
	local distance = math.max(radius, 0) * math.sqrt(ctx.Random:NextNumber())
	local point = center + Vector3.new(math.cos(angle) * distance, 0, math.sin(angle) * distance)
	return EnemyRandom.ClampToField(ctx, point)
end

return EnemyRandom
