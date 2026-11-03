--!strict
-- 行動「刈り取り」: 稲刈り機の動き。(仕様書 006)
-- 田んぼの西のはしの1本目の線から始め、北→南→北…と往復しながら、線ごとに東へ HarvesterWidth ずつずれる。
-- 仕様書 014:出番になるたびに、入る側をランダムに決める(西 or 東)。東から入るときは、経路を左右反転する
-- (線の数・順番・長さは同じ)。向きは、進む向きに合わせて自動で合う。線ごとに、速さを ±SpeedJitter でゆらす。
-- 北のはしの外側から入り、最後の線を終えて田んぼの外に出たら、ctx.Finished を立てる(EnemyService が消す)。
-- Humanoid も経路探索も使わない。Enter で RunService.Heartbeat(毎フレームの合図)につなぎ、
-- 毎フレーム、少しずつ進めて model:PivotTo で動かす。Exit で必ず切る(つなぎっぱなしにしない)。
-- 方角: 北が -Z、南が +Z、東が +X、西が -X。

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Types = require(script.Parent.Parent.Types)
local Stats = require(script.Parent.Parent.Stats)
local EnemyRandom = require(script.Parent.Parent.EnemyRandom)
local SweepRoute = require(script.Parent.Parent.SweepRoute)
-- Behaviors → Enemy → Services の順に上がって、FieldService を読み込む(FieldService は Config だけを使うので、循環しない)
local FieldService = require(script.Parent.Parent.Parent.FieldService)
-- 難易度(入るまでの待ち)を読む。SetupService は、ほかのサービスを読み込まないので、循環しない(仕様書 015)
local SetupService = require(script.Parent.Parent.Parent.SetupService)

-- 稲刈り機1台ぶんの、動きの記憶
type SweepState = {
	Connection: RBXScriptConnection?, -- Heartbeat とのつなぎ
	Points: { Vector3 }, -- 経路の角の点(順番に結ぶ)
	Cumulative: { number }, -- 各点までの、経路に沿った累計の長さ(Cumulative[1] = 0)
	Total: number, -- 経路全体の長さ
	Distance: number, -- いままで進んだ長さ
	Segment: number, -- いま走っている区間の番号(Points[Segment] → Points[Segment + 1])
	SpeedFactors: { number }, -- 区間ごとの、速さにかける倍率(線ごとにランダム。線と線の間のずれは、前の線と同じ)
	WaitLeft: number, -- 動き始めるまでの残り秒数
	Emitting: boolean, -- 粒子(刈りくず・土ぼこり)とエンジン音が出ている最中か。変わったときだけ書く
}

local states: { [Types.Context]: SweepState } = {} -- ctx ごとの記憶(Exit で消す)

-- model を point に置いて、direction(横向きの向き)に向ける。
-- モデルの基準点は「機械の底」なので、y を床の上面にすれば、底が床につく
local function placeModel(model: Model, point: Vector3, direction: Vector3)
	model:PivotTo(CFrame.lookAt(point, point + direction))
end

-- 入ってくるまでの待ち(秒)。基本の長さに、難易度のボーナス(HarvesterEntryDelayBonus。足す秒数)を足す。
-- 難易度は、いちばん新しく「スタート」を押したプレイヤーのもの。短くしても、最低 Config.HarvesterEntryDelayMinSeconds は待つ。
-- (予告「稲刈り機が動き出した!」は、クライアントが、この待ちと同じ計算の長さ + Config.HarvesterWarningExtraSeconds だけ出す。GuiController)
local function entryDelaySeconds(): number
	local bonus = SetupService.GetLatestDifficultyParams().HarvesterEntryDelayBonus
	if type(bonus) ~= "number" or bonus ~= bonus or math.abs(bonus) == math.huge then
		bonus = 0
	end
	return math.max(Config.HarvesterEntryDelaySeconds + bonus, Config.HarvesterEntryDelayMinSeconds)
end

-- 区間 segment の進む向き(長さ1)。長さ0なら南向き
local function segmentDirection(state: SweepState, segment: number): Vector3
	local delta = state.Points[segment + 1] - state.Points[segment]
	if delta.Magnitude < 1e-6 then
		return Vector3.new(0, 0, 1)
	end
	return delta.Unit
end

-- 区間ごとの速さの倍率を作る。線(奇数番目の区間)ごとにランダムに決め、
-- 線と線の間をつなぐ区間(偶数番目)は、前の線と同じ倍率にする
local function buildSpeedFactors(ctx: Types.Context, segmentCount: number): { number }
	local factors: { number } = {}
	for segment = 1, segmentCount do
		if segment % 2 == 1 then
			factors[segment] = EnemyRandom.Jitter(ctx, "SpeedJitter")
		else
			factors[segment] = factors[segment - 1]
		end
	end
	return factors
end

-- 進んだ長さに合わせて、区間の番号を進める
local function advanceSegment(state: SweepState)
	local lastSegment = #state.Points - 1
	while state.Segment < lastSegment and state.Distance > state.Cumulative[state.Segment + 1] do
		state.Segment += 1
	end
end

-- 粒子の名前(HarvesterModel でつけた名前と同じ)
local CHAFF_EMITTER_NAME = "ChaffEmitter"
local DUST_EMITTER_NAME = "DustEmitter"

-- モデルの中から粒子を探して、Enabled を切り替える。見つからない・壊れていても、何もしない(エラーにしない)
local function setEmitterEnabled(model: Model, emitterName: string, enabled: boolean)
	local found = model:FindFirstChild(emitterName, true)
	if found and found:IsA("ParticleEmitter") then
		found.Enabled = enabled
	end
end

-- エンジン音の名前(HarvesterModel でつけた名前と同じ)
local ENGINE_SOUND_NAME = "EngineSound"

-- モデルの中からエンジン音を探して、Playing を切り替える。無い(ID が空)・壊れていても、何もしない
local function setEngineSoundPlaying(model: Model, playing: boolean)
	local found = model:FindFirstChild(ENGINE_SOUND_NAME, true)
	if found and found:IsA("Sound") then
		found.Playing = playing
	end
end

-- 粒子とエンジン音を出す・止める。状態が変わったときだけ書く(毎フレームは書かない)
local function setEmitting(model: Model, state: SweepState, emitting: boolean)
	if state.Emitting == emitting then
		return
	end
	state.Emitting = emitting
	setEmitterEnabled(model, CHAFF_EMITTER_NAME, emitting)
	setEmitterEnabled(model, DUST_EMITTER_NAME, emitting)
	setEngineSoundPlaying(model, emitting)
end

-- Heartbeat とのつなぎを切る(何回呼んでもよい)
local function disconnect(state: SweepState)
	local connection = state.Connection
	state.Connection = nil
	if connection then
		connection:Disconnect()
	end
end

-- 最後まで進んだ:その場に置き、つなぎを切って、「終わった」印を立てる
local function finish(ctx: Types.Context, state: SweepState)
	setEmitting(ctx.Model, state, false)
	disconnect(state)
	ctx.Finished = true
end

-- 毎フレーム1回:待ち時間を数え、終わったら速さぶん進めて、モデルを動かす
local function step(ctx: Types.Context, state: SweepState, frameSeconds: number)
	if ctx.Model.Parent == nil then
		return -- モデルがもう無い(EnemyService が片付ける)
	end
	local dt = math.min(frameSeconds, Config.HarvesterMaxStepSeconds)
	if state.WaitLeft > 0 then
		state.WaitLeft -= dt -- 入ってくる前の待ち(モデルは入り口で止めておく)
		return
	end
	setEmitting(ctx.Model, state, true) -- 実際に進んでいる間だけ粒子を出す
	local speed = Stats.Get(ctx.Definition, "Speed", nil) * (state.SpeedFactors[state.Segment] or 1)
	state.Distance = math.min(state.Distance + dt * speed, state.Total)
	advanceSegment(state)

	local segment = state.Segment
	local startPoint = state.Points[segment]
	local direction = segmentDirection(state, segment)
	local along = state.Distance - state.Cumulative[segment]
	placeModel(ctx.Model, startPoint + direction * along, direction)
	-- 通ったところの稲を刈る。モデルの基準点は「真ん中の底」で、正面が -Z なので、そのまま長方形の中心にできる
	FieldService.CutRice(ctx.Model:GetPivot(), Config.HarvesterWidth, Config.HarvesterLength)

	if state.Distance >= state.Total then
		finish(ctx, state)
	end
end

local function enter(ctx: Types.Context)
	local old = states[ctx]
	if old then
		disconnect(old) -- 念のため:前のつなぎが残っていたら切る
	end
	local fromEast = ctx.Random:NextInteger(0, 1) == 1 -- 入る側:毎回、ランダムに西か東
	local points = SweepRoute.Build(fromEast)
	local state: SweepState = {
		Connection = nil,
		Points = points,
		Cumulative = SweepRoute.BuildCumulative(points),
		Total = 0,
		Distance = 0,
		Segment = 1,
		SpeedFactors = buildSpeedFactors(ctx, #points - 1),
		WaitLeft = entryDelaySeconds(),
		Emitting = false,
	}
	state.Total = state.Cumulative[#points]
	states[ctx] = state

	ctx.Finished = false
	placeModel(ctx.Model, points[1], segmentDirection(state, 1)) -- 入り口で待つ(田んぼの外)
	state.Connection = RunService.Heartbeat:Connect(function(frameSeconds: number)
		step(ctx, state, frameSeconds)
	end)
end

-- 動かすのは Heartbeat が行うので、毎回の判断では何もしない(次の行動もない)
local function update(_ctx: Types.Context, _dt: number): string?
	return nil
end

local function exit(ctx: Types.Context)
	local state = states[ctx]
	states[ctx] = nil
	if state then
		setEmitting(ctx.Model, state, false) -- モデルが消える前に粒子を止める
		disconnect(state)
	end
end

local Sweep: Types.Behavior = {
	Enter = enter,
	Update = update,
	Exit = exit,
}

return Sweep
