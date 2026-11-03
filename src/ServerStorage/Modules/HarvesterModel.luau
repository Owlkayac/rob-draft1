--!strict
-- 稲刈り機の「見た目」だけを作る部品。動きと判定は、Sweep と Harvester(定義)が行う。(仕様書 006)
-- 図形(Part)だけで作る。外部の素材は使わない。
-- モデルの向き: 正面は -Z。全体の長さ=HarvesterLength、幅=HarvesterWidth、高さ=HarvesterHeight。
-- モデルの基準点(Pivot)は「機械の真ん中の、底の高さ」。
-- なので、PivotTo で床の高さに置けば、底がぴったり床につく。

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)

local HarvesterModel = {}

-- 動かない図形を1つ作る。当たり判定は全部切る(動きはコードで、位置を毎フレーム動かす)
local function makePart(name: string, size: Vector3, position: Vector3, color: Color3): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CFrame = CFrame.new(position)
	return part
end

-- 車輪(円柱)を1つ作る。円柱は X 方向が「厚さ」になるので、回さずに横向きの車輪になる
local function makeWheel(name: string, x: number, z: number): Part
	local diameter = Config.HarvesterWheelDiameter
	local wheel = makePart(
		name,
		Vector3.new(Config.HarvesterWheelThickness, diameter, diameter),
		Vector3.new(x, diameter / 2, z),
		Config.HarvesterWheelColor
	)
	wheel.Shape = Enum.PartType.Cylinder
	return wheel
end

-- 稲刈り機のモデルを作って返す(Workspace にはまだ入れない)
function HarvesterModel.Create(): Model
	local width = Config.HarvesterWidth
	local length = Config.HarvesterLength
	local wheelD = Config.HarvesterWheelDiameter
	local wheelT = Config.HarvesterWheelThickness
	local bladeLength = Config.HarvesterBladeLength
	local frontZ = -length / 2 -- 機械の先頭(正面)の Z

	local model = Instance.new("Model")
	model.Name = "Harvester"

	-- 胴体(大きな箱):車輪の中心の高さから上。刃より後ろ。横は車輪の内側
	local bodyWidth = width - 2 * wheelT
	local bodyLength = length - bladeLength
	local bodyY = wheelD / 2 + Config.HarvesterBodyHeight / 2
	local body = makePart(
		"Body",
		Vector3.new(bodyWidth, Config.HarvesterBodyHeight, bodyLength),
		Vector3.new(0, bodyY, frontZ + bladeLength + bodyLength / 2),
		Config.HarvesterColor
	)

	-- 運転席(小さな箱):胴体の上の前のほう。てっぺんが HarvesterHeight になる
	local bodyTop = wheelD / 2 + Config.HarvesterBodyHeight
	local cabinHeight = math.max(Config.HarvesterHeight - bodyTop, 1)
	local cabin = makePart(
		"Cabin",
		Vector3.new(bodyWidth * Config.HarvesterCabinWidthRatio, cabinHeight, Config.HarvesterCabinLength),
		Vector3.new(0, bodyTop + cabinHeight / 2, frontZ + bladeLength + Config.HarvesterCabinLength / 2),
		Config.HarvesterCabinColor
	)

	-- 前の刈り取りの刃(横長の箱):幅は HarvesterWidth。底は床の高さ
	local blade = makePart(
		"Blade",
		Vector3.new(width, Config.HarvesterBladeHeight, bladeLength),
		Vector3.new(0, Config.HarvesterBladeHeight / 2, frontZ + bladeLength / 2),
		Config.HarvesterBladeColor
	)

	-- 車輪4つ:左右の端、前と後ろ
	local wheelX = width / 2 - wheelT / 2
	local frontWheelZ = frontZ + bladeLength + wheelD / 2
	local rearWheelZ = length / 2 - wheelD / 2
	local wheels = {
		makeWheel("WheelFrontLeft", -wheelX, frontWheelZ),
		makeWheel("WheelFrontRight", wheelX, frontWheelZ),
		makeWheel("WheelRearLeft", -wheelX, rearWheelZ),
		makeWheel("WheelRearRight", wheelX, rearWheelZ),
	}

	body.Parent = model
	cabin.Parent = model
	blade.Parent = model
	for _, wheel in wheels do
		wheel.Parent = model
	end

	-- 基準点を「機械の真ん中の底」(原点)に合わせる。PivotOffset は、胴体の位置からのずれ
	body.PivotOffset = body.CFrame:Inverse()
	model.PrimaryPart = body
	return model
end

return HarvesterModel
