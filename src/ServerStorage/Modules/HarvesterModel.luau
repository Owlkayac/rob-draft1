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

-- 刈りくずの粒子(ParticleEmitter)を作る。Enabled=false で作り、動いている間だけ Sweep が true にする。
-- 粒子の画像(Texture)は設定しない(Roblox の既定のまま)。向きは Attachment から見た「前」(-Z)
local function makeChaffEmitter(): ParticleEmitter
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "ChaffEmitter"
	emitter.Enabled = false
	emitter.Rate = Config.HarvesterChaffRate
	emitter.Lifetime = NumberRange.new(Config.HarvesterChaffLifetimeMin, Config.HarvesterChaffLifetimeMax)
	emitter.Speed = NumberRange.new(Config.HarvesterChaffSpeedMin, Config.HarvesterChaffSpeedMax)
	emitter.Color = ColorSequence.new(Config.HarvesterChaffColorStart, Config.HarvesterChaffColorEnd)
	emitter.Size = NumberSequence.new(Config.HarvesterChaffSizeStart, Config.HarvesterChaffSizeEnd) -- だんだん小さく
	emitter.Transparency = NumberSequence.new(Config.HarvesterChaffTransparencyStart, 1) -- だんだん透明に
	emitter.Acceleration = Config.HarvesterChaffAcceleration
	emitter.EmissionDirection = Enum.NormalId.Front -- Attachment から見た「前」。Attachment を上向きに傾けてあるので、前と上の間に飛ぶ
	emitter.SpreadAngle = Config.HarvesterChaffSpreadAngle
	emitter.LightEmission = Config.HarvesterChaffLightEmission
	emitter.Rotation = NumberRange.new(0, Config.HarvesterParticleRotationMaxDeg)
	emitter.RotSpeed = NumberRange.new(-Config.HarvesterChaffRotSpeedDeg, Config.HarvesterChaffRotSpeedDeg)
	return emitter
end

-- 刈りくずの発生源:刃の前の上の角にある Attachment(印)。前向き(-Z)を、上へ傾けておく。
-- ParticleEmitter の向きは「面」(前・上など)でしか選べないので、Attachment を傾けて、前と上の間に飛ばす。
-- 傾きの角度 = atan(上向きの強さ / 前向きの強さ 1)。プラスの X 回転で、前(-Z)が上へ向く
local function makeChaffSource(blade: Part)
	local attachment = Instance.new("Attachment")
	attachment.Name = "ChaffSource"
	attachment.Position = Vector3.new(0, blade.Size.Y / 2, -blade.Size.Z / 2)
	attachment.CFrame = CFrame.new(attachment.Position) * CFrame.Angles(math.atan(Config.HarvesterChaffUpwardRatio), 0, 0)
	attachment.Parent = blade
	makeChaffEmitter().Parent = attachment
end

-- 土ぼこりの粒子を作る。Enabled=false で作る。向きは Part から見た「上」
local function makeDustEmitter(): ParticleEmitter
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "DustEmitter"
	emitter.Enabled = false
	emitter.Rate = Config.HarvesterDustRate
	emitter.Lifetime = NumberRange.new(Config.HarvesterDustLifetimeMin, Config.HarvesterDustLifetimeMax)
	emitter.Speed = NumberRange.new(Config.HarvesterDustSpeedMin, Config.HarvesterDustSpeedMax)
	emitter.Color = ColorSequence.new(Config.HarvesterDustColor)
	emitter.Size = NumberSequence.new(Config.HarvesterDustSizeStart, Config.HarvesterDustSizeEnd) -- だんだん大きく(ふんわり広がる)
	emitter.Transparency = NumberSequence.new(Config.HarvesterDustTransparencyStart, 1) -- だんだん透明に
	emitter.Acceleration = Config.HarvesterDustAcceleration
	emitter.Drag = Config.HarvesterDustDrag
	emitter.EmissionDirection = Enum.NormalId.Top
	emitter.SpreadAngle = Config.HarvesterDustSpreadAngle
	emitter.LightEmission = Config.HarvesterDustLightEmission
	emitter.Rotation = NumberRange.new(0, Config.HarvesterParticleRotationMaxDeg)
	emitter.RotSpeed = NumberRange.new(-Config.HarvesterDustRotSpeedDeg, Config.HarvesterDustRotSpeedDeg)
	return emitter
end

-- 土ぼこりの発生源:後ろの車輪のあたりの、見えない薄い箱。底は床の高さ(モデルの大きさの計算を変えない)
local function makeDustSource(bodyWidth: number, length: number): Part
	local sourceHeight = Config.HarvesterDustSourceHeight
	local sourceLength = Config.HarvesterDustSourceLength
	local source = makePart(
		"DustSource",
		Vector3.new(bodyWidth, sourceHeight, sourceLength),
		Vector3.new(0, sourceHeight / 2, length / 2 - sourceLength / 2),
		Config.HarvesterWheelColor
	)
	source.Transparency = 1 -- 見えない(粒子だけ見える)
	makeDustEmitter().Parent = source
	return source
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

	makeChaffSource(blade) -- 刈りくず:刃から(前と上へ)
	local dustSource = makeDustSource(bodyWidth, length)

	body.Parent = model
	dustSource.Parent = model
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
