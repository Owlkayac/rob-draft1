--!strict
-- ザリガニの「見た目」だけを作る部品。動きの判断は CrayfishService が行う。(仕様書 005)
-- 外部の素材は使わず、図形(Part)だけで作る。
-- 人型(Humanoid)は動きと当たり判定の土台として残し、人型の見た目は透明にして隠す。
-- ザリガニの図形は HumanoidRootPart に溶接(WeldConstraint)して、ついて歩かせる。
-- ただし、動かす部品(足・はさみ・ひげ。仕様書 010)は、胴体(Body)に Motor6D(関節)でつなぐ。
--   Motor6D は「Part1 の位置 = Part0 の位置 * C0 * Transform * C1 の逆」で決まる。
--   C0 = 胴体から見た関節の位置、C1 = 動かす部品から見た同じ関節の位置。
--   Transform が単位(何もしない)のときは、WeldConstraint で溶接したときと同じ位置になる。
--   Transform を回すと、関節の位置を中心に部品が回る(クライアントの CrayfishAnimator が毎フレーム回す)。
--
-- 向き:Part の「正面」は -Z 方向。ザリガニは Z 方向に長く、はさみと目は -Z(前)に向ける。
-- 組み立てる時の座標(「ローカル座標」)は、足元の地面の点を原点(0,0,0)とする。
--   X = 右、Y = 上、Z = 後ろ(前が -Z)

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)

local CrayfishModel = {}

local VISUAL_FOLDER_NAME = "CrayfishVisual"
-- 組み立てたときの高さの材料を、CrayfishVisual に覚えておく名前(あとで値が変わったか比べる)
local ATTR_HIP_HEIGHT = "BuiltHipHeight"
local ATTR_ROOT_SIZE_Y = "BuiltRootSizeY"
local SAME_VALUE_TOLERANCE = 0.001 -- この差までは「同じ値」とみなす

-- ===== 外見の細部の数字(Config には入れず、ここにまとめる) =====
local BASE_LENGTH = 4.5 -- この長さを基準に、Config.CrayfishBodyLength 倍率で全体を伸び縮みさせる
local BODY_WIDTH = 1.9 -- 胴体の幅
local BODY_LENGTH_RATIO = 2.0 -- 胴体の長さ(単位長さ u の何倍か)
local BODY_Z_RATIO = -0.4 -- 胴体の中心の前後位置(u 倍)
local BODY_LIFT_RATIO = 0.25 -- 胴体の底の高さ(高さ H の何倍か。足で持ち上げている分)
local BODY_HEIGHT_RATIO = 0.65 -- 胴体の高さ(H の何倍か)

local TAIL_COUNT = 4 -- しっぽの節の数
local TAIL_FIRST_WIDTH = 1.5 -- 最初の節の幅
local TAIL_WIDTH_STEP = 0.2 -- 節ごとに細くする量
local TAIL_HEIGHT_RATIO = 0.45 -- 最初の節の高さ(H の何倍か)
local TAIL_HEIGHT_STEP_RATIO = 0.05 -- 節ごとに低くする量(H の何倍か)
local TAIL_SEGMENT_LENGTH_RATIO = 0.4 -- 1節の長さ(u 倍)
local TAIL_SEGMENT_PITCH_RATIO = 0.34 -- 節の並ぶ間隔(u 倍。少し重ねる)
local TAIL_START_Z_RATIO = 0.6 -- しっぽの始まりの位置(u 倍。胴体の後ろ端)
local FIN_WIDTH = 1.4 -- ひれの幅
local FIN_THICKNESS = 0.1 -- ひれの厚さ
local FIN_LENGTH_RATIO = 0.5 -- ひれの長さ(u 倍)

local BELLY_WIDTH = 0.8 -- お腹の板の幅
local BELLY_THICKNESS = 0.1 -- お腹の板の厚さ
local BELLY_LENGTH_RATIO = 3.2 -- お腹の板の長さ(u 倍)
local BELLY_Z_RATIO = 0.9 -- お腹の板の中心の位置(u 倍)

local CLAW_SIDE_X = 1.0 -- はさみの球の、中心線からの左右の距離
local CLAW_PALM_SIZE = Vector3.new(1.0, 0.6, 1.1) -- はさみの球の大きさ(Y は H 倍、Z は u 倍)
local CLAW_PALM_Z_RATIO = -1.6 -- はさみの球の位置(u 倍)
local CLAW_Y_RATIO = 0.45 -- はさみの高さ(H 倍)
local CLAW_ARM_SIZE = Vector3.new(0.35, 0.35, 0.8) -- 腕(Z は u 倍)
local CLAW_ARM_X = 0.8 -- 腕の左右位置
local CLAW_ARM_Z_RATIO = -1.3 -- 腕の位置(u 倍)
local CLAW_TIP_SIZE = Vector3.new(0.35, 0.25, 0.7) -- はさみの先の小さな箱(Y は H 倍、Z は u 倍)
local CLAW_TIP_X = 0.95 -- 先の左右位置
local CLAW_TIP_Z_RATIO = -2.0 -- 先の位置(u 倍)

local EYE_X = 0.45 -- 目の左右位置
local EYE_Z_RATIO = -1.35 -- 目の前後位置(u 倍)
local EYE_STALK_BOTTOM_RATIO = 0.7 -- 目の柱の根元の高さ(H 倍)
local EYE_STALK_THICKNESS = 0.12 -- 目の柱の太さ
local EYE_BALL_SIZE = 0.3 -- 目玉の直径

local ANTENNA_X = 0.3 -- ひげの根元の左右位置
local ANTENNA_START_Z_RATIO = -1.3 -- ひげの根元の前後位置(u 倍)
local ANTENNA_START_Y_RATIO = 0.6 -- ひげの根元の高さ(H 倍)
local ANTENNA_LENGTH_RATIO = 1.6 -- ひげの長さ(u 倍)
local ANTENNA_PITCH_DEGREES = 15 -- ひげを上に向ける角度
local ANTENNA_SPREAD = 0.4 -- ひげの先を外側に開く量
local ANTENNA_THICKNESS = 0.08 -- ひげの太さ

local LEG_PAIRS_Z_RATIOS = { -0.8, -0.3, 0.2 } -- 足の前後位置(u 倍)。左右に3本ずつ
local LEG_ROOT_X = 0.7 -- 足の根元の左右位置
local LEG_ROOT_Y_RATIO = 0.35 -- 足の根元の高さ(H 倍)
local LEG_TIP_X = 1.25 -- 足の先の左右位置(足先は地面)
local LEG_THICKNESS = 0.12 -- 足の太さ

-- 組み立ての間、ずっと使う情報
type Context = {
	Root: BasePart, -- 溶接先(HumanoidRootPart)
	Base: CFrame, -- ローカル座標の原点(足元の地面の点)のワールドでの位置と向き
	Folder: Folder, -- CrayfishVisual
	U: number, -- 前後の単位長さ(全長 / 基準の長さ)
	H: number, -- 高さの目安(Config.CrayfishBodyHeight)
	Body: BasePart?, -- 胴体(Motor6D の土台。buildBody で入る)
}

type ShapeKind = "Block" | "Ball" | "Cylinder" | "Ellipsoid"

-- Part を1つ作って、フォルダに入れる(つなぐのは、あとで weldParts か addMotor で行う)。
-- Ellipsoid は「つぶした球」:箱に球のメッシュ(SpecialMesh)をつけて作る(Ball は縦横を変えにくいため)
local function addPart(
	ctx: Context,
	name: string,
	kind: ShapeKind,
	size: Vector3,
	localCFrame: CFrame,
	color: Color3
): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.Anchored = false
	part.CanCollide = false -- 歩く邪魔にならないように
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true -- 重さを持たない
	if kind == "Ball" then
		part.Shape = Enum.PartType.Ball
	elseif kind == "Cylinder" then
		part.Shape = Enum.PartType.Cylinder -- 円柱は X 方向が「長さ」
	elseif kind == "Ellipsoid" then
		local mesh = Instance.new("SpecialMesh")
		mesh.MeshType = Enum.MeshType.Sphere
		mesh.Parent = part
	end
	part.CFrame = ctx.Base * localCFrame
	part.Parent = ctx.Folder
	return part
end

-- 2つの部品を WeldConstraint(固定)でつなぐ。weld は part1 の子に置く
local function weldParts(part0: BasePart, part1: BasePart)
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = part0
	weld.Part1 = part1
	weld.Parent = part1
end

-- 動かさない部品を作って、HumanoidRootPart に溶接する
local function addFixedPart(
	ctx: Context,
	name: string,
	kind: ShapeKind,
	size: Vector3,
	localCFrame: CFrame,
	color: Color3
): Part
	local part = addPart(ctx, name, kind, size, localCFrame, color)
	weldParts(ctx.Root, part)
	return part
end

-- 部品を、胴体に Motor6D(関節)でつなぐ。jointLocal は、関節の位置(ローカル座標)。
-- 関節の向きは、ザリガニの向き(X=右、Y=上、Z=後ろ)に合わせる。
--   joint = 関節のワールドでの位置と向き
--   C0 = (胴体の CFrame の逆) * joint    ... 胴体から見た関節
--   C1 = (部品の CFrame の逆) * joint    ... 部品から見た同じ関節
-- すると 胴体 * C0 * (C1 の逆) = 胴体 * 胴体の逆 * joint * joint の逆 * 部品 = 部品 となり、
-- Transform が単位のときの位置は、いまの位置(溶接のとき)と同じ。
-- 胴体がない(ありえないが)ときは、動かないよう溶接で代用する
local function addMotor(ctx: Context, part: BasePart, motorName: string, jointLocal: Vector3)
	local body = ctx.Body
	if not body then
		weldParts(ctx.Root, part)
		return
	end
	local joint = ctx.Base * CFrame.new(jointLocal)
	local motor = Instance.new("Motor6D")
	motor.Name = motorName
	motor.Part0 = body
	motor.Part1 = part
	motor.C0 = body.CFrame:Inverse() * joint
	motor.C1 = part.CFrame:Inverse() * joint
	motor.Parent = body -- Motor6D は Part0(胴体)の子に置く
end

-- 点 a から点 b までをつなぐ、細い円柱(足、ひげ、目の柱)を作る
-- (つなぐのは呼んだ側。動かす部品は addMotor、動かさない部品は weldParts)
local function addLimb(ctx: Context, name: string, a: Vector3, b: Vector3, thickness: number, color: Color3): Part
	local offset = b - a
	local direction = offset.Unit
	-- 真上に近いときは、向きの計算がおかしくならないよう、基準の「上」を変える
	local upHint = if math.abs(direction.Y) < 0.9 then Vector3.yAxis else Vector3.xAxis
	-- lookAt は -Z を b に向ける。円柱の長い方向は X なので、Y軸まわりに90度回して合わせる
	local cframe = CFrame.lookAt((a + b) / 2, b, upHint) * CFrame.Angles(0, math.rad(90), 0)
	return addPart(ctx, name, "Cylinder", Vector3.new(offset.Magnitude, thickness, thickness), cframe, color)
end

-- 水しぶきの粒子(ParticleEmitter)を作る。Enabled=false で作り、潜る・浮上のときだけ CrayfishService が短く true にする。
-- 粒子の画像(Texture)は設定しない(Roblox の既定のまま)
local function makeSplashEmitter(): ParticleEmitter
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "SplashEmitter"
	emitter.Enabled = false
	emitter.Rate = Config.SplashRate
	emitter.Lifetime = NumberRange.new(Config.SplashLifetimeMin, Config.SplashLifetimeMax)
	emitter.Speed = NumberRange.new(Config.SplashSpeedMin, Config.SplashSpeedMax)
	emitter.Color = ColorSequence.new(Config.SplashColor)
	emitter.Size = NumberSequence.new(Config.SplashSizeStart, Config.SplashSizeEnd) -- だんだん小さく
	emitter.Transparency = NumberSequence.new(Config.SplashTransparencyStart, 1) -- だんだん透明に
	emitter.Acceleration = Config.SplashAcceleration
	emitter.EmissionDirection = Enum.NormalId.Top
	emitter.SpreadAngle = Config.SplashSpreadAngle
	emitter.LightEmission = Config.SplashLightEmission
	return emitter
end

-- 胴体とお腹の板
local function buildBody(ctx: Context)
	local u, h = ctx.U, ctx.H
	local bodyHeight = h * BODY_HEIGHT_RATIO
	local lift = h * BODY_LIFT_RATIO
	local body = addFixedPart(
		ctx,
		"Body",
		"Ellipsoid",
		Vector3.new(BODY_WIDTH, bodyHeight, u * BODY_LENGTH_RATIO),
		CFrame.new(0, lift + bodyHeight / 2, u * BODY_Z_RATIO),
		Config.CrayfishColor
	)
	ctx.Body = body -- 動かす部品の Motor6D は、この胴体につなぐ
	makeSplashEmitter().Parent = body -- 水しぶきは胴体から(Attach で作り直されても、新しい胴体につく)
	-- お腹側:明るい色の薄い板を、胴体としっぽの下に
	addFixedPart(
		ctx,
		"Belly",
		"Block",
		Vector3.new(BELLY_WIDTH, BELLY_THICKNESS, u * BELLY_LENGTH_RATIO),
		CFrame.new(0, lift + BELLY_THICKNESS / 2, u * BELLY_Z_RATIO),
		Config.CrayfishBellyColor
	)
end

-- しっぽ(節を後ろに並べる)と、尾の先のひれ
local function buildTail(ctx: Context)
	local u, h = ctx.U, ctx.H
	local lift = h * BODY_LIFT_RATIO
	for i = 1, TAIL_COUNT do
		local width = TAIL_FIRST_WIDTH - TAIL_WIDTH_STEP * (i - 1)
		local height = h * (TAIL_HEIGHT_RATIO - TAIL_HEIGHT_STEP_RATIO * (i - 1))
		local z = u * (TAIL_START_Z_RATIO + TAIL_SEGMENT_PITCH_RATIO * (i - 0.5))
		addFixedPart(
			ctx,
			`TailSegment{i}`,
			"Block",
			Vector3.new(width, height, u * TAIL_SEGMENT_LENGTH_RATIO),
			CFrame.new(0, lift + height / 2, z),
			Config.CrayfishColor
		)
	end
	local finLength = u * FIN_LENGTH_RATIO
	local finZ = u * (TAIL_START_Z_RATIO + TAIL_SEGMENT_PITCH_RATIO * TAIL_COUNT) + finLength / 2
	addFixedPart(
		ctx,
		"TailFin",
		"Block",
		Vector3.new(FIN_WIDTH, FIN_THICKNESS, finLength),
		CFrame.new(0, lift + FIN_THICKNESS / 2 + 0.05, finZ),
		Config.CrayfishColor
	)
end

-- 大きなはさみ(腕+球+先の小さな箱)。side は左右(-1 か 1)
local function buildClaw(ctx: Context, side: number)
	local u, h = ctx.U, ctx.H
	local suffix = if side < 0 then "L" else "R"
	local y = h * CLAW_Y_RATIO
	local color = Config.CrayfishColor
	local arm = addPart(
		ctx,
		`ClawArm{suffix}`,
		"Block",
		Vector3.new(CLAW_ARM_SIZE.X, CLAW_ARM_SIZE.Y, u * CLAW_ARM_SIZE.Z),
		CFrame.new(side * CLAW_ARM_X, y, u * CLAW_ARM_Z_RATIO),
		color
	)
	local palm = addPart(
		ctx,
		`ClawPalm{suffix}`,
		"Ellipsoid",
		Vector3.new(CLAW_PALM_SIZE.X, h * CLAW_PALM_SIZE.Y, u * CLAW_PALM_SIZE.Z),
		CFrame.new(side * CLAW_SIDE_X, y, u * CLAW_PALM_Z_RATIO),
		color
	)
	local tip = addPart(
		ctx,
		`ClawTip{suffix}`,
		"Block",
		Vector3.new(CLAW_TIP_SIZE.X, h * CLAW_TIP_SIZE.Y, u * CLAW_TIP_SIZE.Z),
		CFrame.new(side * CLAW_TIP_X, y, u * CLAW_TIP_Z_RATIO),
		color
	)
	-- 球と先の箱は、腕に固定する(腕が動くと、いっしょに動く)
	weldParts(arm, palm)
	weldParts(arm, tip)
	-- 関節は、腕の後ろ端(胴体に近い側)
	local joint = Vector3.new(side * CLAW_ARM_X, y, u * (CLAW_ARM_Z_RATIO + CLAW_ARM_SIZE.Z / 2))
	addMotor(ctx, arm, `Claw{suffix}`, joint)
end

-- 目(細い柱の先に黒い球)。side は左右(-1 か 1)
local function buildEye(ctx: Context, side: number)
	local u, h = ctx.U, ctx.H
	local suffix = if side < 0 then "L" else "R"
	local bottom = Vector3.new(side * EYE_X, h * EYE_STALK_BOTTOM_RATIO, u * EYE_Z_RATIO)
	local top = Vector3.new(side * EYE_X, h - EYE_BALL_SIZE / 2, u * EYE_Z_RATIO)
	local stalk = addLimb(ctx, `EyeStalk{suffix}`, bottom, top, EYE_STALK_THICKNESS, Config.CrayfishColor)
	weldParts(ctx.Root, stalk)
	addFixedPart(
		ctx,
		`Eye{suffix}`,
		"Ball",
		Vector3.new(EYE_BALL_SIZE, EYE_BALL_SIZE, EYE_BALL_SIZE),
		CFrame.new(top),
		Config.CrayfishEyeColor
	)
end

-- ひげ(前と少し上に伸びる細長い円柱)。side は左右(-1 か 1)
local function buildAntenna(ctx: Context, side: number)
	local u, h = ctx.U, ctx.H
	local suffix = if side < 0 then "L" else "R"
	local pitch = math.rad(ANTENNA_PITCH_DEGREES)
	local length = u * ANTENNA_LENGTH_RATIO
	local start = Vector3.new(side * ANTENNA_X, h * ANTENNA_START_Y_RATIO, u * ANTENNA_START_Z_RATIO)
	local tip = start + Vector3.new(side * ANTENNA_SPREAD, math.sin(pitch) * length, -math.cos(pitch) * length)
	local antenna = addLimb(ctx, `Antenna{suffix}`, start, tip, ANTENNA_THICKNESS, Config.CrayfishBellyColor)
	addMotor(ctx, antenna, `Antenna{suffix}`, start) -- 関節は、ひげの根元
end

-- 足(左右に3本ずつ)。side は左右(-1 か 1)
local function buildLegs(ctx: Context, side: number)
	local u, h = ctx.U, ctx.H
	local suffix = if side < 0 then "L" else "R"
	for i, zRatio in LEG_PAIRS_Z_RATIOS do
		local root = Vector3.new(side * LEG_ROOT_X, h * LEG_ROOT_Y_RATIO, u * zRatio)
		local tip = Vector3.new(side * LEG_TIP_X, 0, u * zRatio)
		local leg = addLimb(ctx, `Leg{suffix}{i}`, root, tip, LEG_THICKNESS, Config.CrayfishBellyColor)
		addMotor(ctx, leg, `Leg{suffix}{i}`, root) -- 関節は、足の付け根
	end
end

-- 左右ある部品を、左右とも作る
local function buildBothSides(ctx: Context)
	for _, side in { -1, 1 } do
		buildClaw(ctx, side)
		buildEye(ctx, side)
		buildAntenna(ctx, side)
		buildLegs(ctx, side)
	end
end

-- キャラクターから Humanoid と HumanoidRootPart を取り出す。そろっていなければ nil
local function getHumanoidAndRoot(character: Model): (Humanoid?, BasePart?)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root or not root:IsA("BasePart") then
		return nil, nil
	end
	return humanoid, root
end

-- 2つの数字が(ほぼ)同じか
local function isSameValue(a: number, b: number): boolean
	return math.abs(a - b) <= SAME_VALUE_TOLERANCE
end

-- 古い CrayfishVisual が、いまの HipHeight と HumanoidRootPart の高さで作られたものか。
-- 覚えていない(Attribute がない)ときは、違うものとして扱い、作り直す
local function isVisualUpToDate(visual: Instance, humanoid: Humanoid, root: BasePart): boolean
	local hip = visual:GetAttribute(ATTR_HIP_HEIGHT)
	local sizeY = visual:GetAttribute(ATTR_ROOT_SIZE_Y)
	if typeof(hip) ~= "number" or typeof(sizeY) ~= "number" then
		return false
	end
	return isSameValue(hip, humanoid.HipHeight) and isSameValue(sizeY, root.Size.Y)
end

-- キャラクターに、ザリガニの見た目をつける。成功したら true、失敗したら false を返す。
-- すでに CrayfishVisual があり、HipHeight と HumanoidRootPart の高さが同じなら、何もしない(2回呼ばれても安全)。
-- 服や体の大きさがあとから読み込まれて高さが変わったときは、古い CrayfishVisual を消して作り直す。
-- 壊れたキャラクターでは何もせず false を返す(警告は呼んだ側が出す)。
function CrayfishModel.Attach(character: Model): boolean
	local humanoid, root = getHumanoidAndRoot(character)
	if not humanoid or not root then
		return false
	end
	local existing = character:FindFirstChild(VISUAL_FOLDER_NAME)
	if existing then
		if isVisualUpToDate(existing, humanoid, root) then
			return true
		end
		existing:Destroy() -- 高さが変わったので、古いものを消して作り直す
	end

	-- 足元は、HumanoidRootPart の中心から (HipHeight + 高さの半分) だけ下。CrayfishGroundOffset は調整値
	local groundDrop = humanoid.HipHeight + root.Size.Y / 2
	local folder = Instance.new("Folder")
	folder.Name = VISUAL_FOLDER_NAME
	folder:SetAttribute(ATTR_HIP_HEIGHT, humanoid.HipHeight)
	folder:SetAttribute(ATTR_ROOT_SIZE_Y, root.Size.Y)
	local ctx: Context = {
		Root = root,
		Base = root.CFrame * CFrame.new(0, -groundDrop + Config.CrayfishGroundOffset, 0),
		Folder = folder,
		U = Config.CrayfishBodyLength / BASE_LENGTH,
		H = Config.CrayfishBodyHeight,
	}
	buildBody(ctx)
	buildTail(ctx)
	buildBothSides(ctx)
	folder.Parent = character -- 全部できてから入れる
	return true
end

-- 人型の見た目を、すべて隠す(HumanoidRootPart と CrayfishVisual の中身は除く)。
-- 服や髪は、あとから読み込まれるので、何回呼んでもよい。
function CrayfishModel.HideAvatar(character: Model)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local visual = character:FindFirstChild(VISUAL_FOLDER_NAME)
	for _, descendant in character:GetDescendants() do
		if visual and descendant:IsDescendantOf(visual) then
			continue
		end
		if descendant:IsA("BasePart") then
			if descendant.Name ~= "HumanoidRootPart" then
				descendant.Transparency = 1
			end
		elseif descendant:IsA("Decal") or descendant:IsA("Texture") then
			descendant.Transparency = 1
		end
	end
	if humanoid then
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None -- 名前を表示しない
		humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff -- 体力バーも出さない
	end
end

return CrayfishModel
