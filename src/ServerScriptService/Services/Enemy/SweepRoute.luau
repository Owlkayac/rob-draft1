--!strict
-- 稲刈り機の「経路」(通る道すじ)を計算する小さな部品。(仕様書 006)
-- Sweep(動き)と Harvester(定義:置き場所)の両方が使う。読み込むのは Config だけ(循環 require を作らない)。
-- 方角: 北が -Z、南が +Z、東が +X、西が -X。
-- 入る側(仕様書 014 の 1-4):西から入る経路を基本にして、東から入るときは、点の x を -x にして左右を反転する。
--   点の順番・数・長さ・南北の向きは、同じ。反転しても、刈り残しは出ない:
--   基本の経路は、線の中心 x0 + k×幅(k = 0..n-2)と、最後の東の限度 xEast で、
--   x0 - 幅/2 から xEast + 幅/2 までを、すきまなく覆う(線の間隔は幅以下)。
--   反転した経路の中心は、-x0 - k×幅(k = 0..n-2)と -xEast で、基本の経路の左右反転そのもの。
--   覆う範囲も左右反転して、-xEast - 幅/2 から -x0 + 幅/2 までを、同じようにすきまなく覆う。
--   田んぼの左右の余白(HarvesterLaneMargin)が同じ(-xEast = x0、-x0 = xEast)なので、
--   どちらの入り方でも、西の端も東の端も覆われる(東の端の刈り残しが、西の端に出ることはない)。

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)

local SweepRoute = {}

-- 西の1本目の線の中心の x(西のはし + 余白)
local function getWestX(): number
	return -Config.FieldSize / 2 + Config.HarvesterLaneMargin
end

-- 東の最後の線の中心の x(東のはし - 余白)
local function getEastX(): number
	return Config.FieldSize / 2 - Config.HarvesterLaneMargin
end

-- 線の数。西の1本目から東の最後まで、HarvesterWidth ずつ進んで、取りこぼしなく覆える数
local function calcLaneCount(): number
	local span = getEastX() - getWestX() -- 1本目から、最後の線までの距離
	if span <= 0 or Config.HarvesterWidth <= 0 then
		return 1
	end
	return math.ceil(span / Config.HarvesterWidth) + 1
end

-- 経路の角の点を作る。fromEast は、東から入るか(true なら左右反転)。線ごとに、北のはしの外 ⇔ 南のはしの外 を行き来する。
-- 線の端の点と、次の線の端の点は同じ Z なので、結ぶと「田んぼの外で東へずれる」動きになる。
-- 線の中心は西から HarvesterWidth ずつ東へ。最後の線だけ東の限度(xEast)に固定する
-- (前の線と重なってよい。これで東のはしまで刈り残しがなくなる)
function SweepRoute.Build(fromEast: boolean): { Vector3 }
	local half = Config.FieldSize / 2
	local y = Config.FieldFloorTopY
	local northZ = -half - Config.HarvesterLength
	local southZ = half + Config.HarvesterLength
	local firstX = getWestX()
	local eastX = getEastX()
	local laneCount = calcLaneCount()
	local points: { Vector3 } = {}
	for lane = 1, laneCount do
		local westBasedX = if lane == laneCount and laneCount > 1 then eastX else firstX + (lane - 1) * Config.HarvesterWidth
		local x = if fromEast then -westBasedX else westBasedX -- 東から入るときは、左右反転
		local fromZ = if lane % 2 == 1 then northZ else southZ
		local toZ = if lane % 2 == 1 then southZ else northZ
		table.insert(points, Vector3.new(x, y, fromZ))
		table.insert(points, Vector3.new(x, y, toZ))
	end
	return points
end

-- 点と点の間の長さの累計を作る
function SweepRoute.BuildCumulative(points: { Vector3 }): { number }
	local cumulative: { number } = { 0 }
	for index = 2, #points do
		cumulative[index] = cumulative[index - 1] + (points[index] - points[index - 1]).Magnitude
	end
	return cumulative
end

-- 入ってくる最初の位置(北のはしの外。1本目の線の上)。fromEast が true なら東側
function SweepRoute.GetStartPoint(fromEast: boolean): Vector3
	return Vector3.new(
		if fromEast then -getWestX() else getWestX(),
		Config.FieldFloorTopY,
		-Config.FieldSize / 2 - Config.HarvesterLength
	)
end

-- 最初に向く向き(南向き)
function SweepRoute.GetStartDirection(): Vector3
	return Vector3.new(0, 0, 1)
end

return SweepRoute
