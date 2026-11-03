--!strict
-- 光と空気をつくる(仕様書 007 の 4)。クライアント(自分の端末)だけで変える。
-- 流れ: RoundState(残り秒数) → 進み具合(0〜1) → なめらかに近づける → Lighting と効果に反映。
-- サーバーの Lighting は変えない。新しい通信も足さない。

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

local LightingController = {}

local ATMOSPHERE_NAME = "FieldAtmosphere"
local COLOR_CORRECTION_NAME = "FieldColorCorrection"
local BLOOM_NAME = "FieldBloom"
local SUN_RAYS_NAME = "FieldSunRays"
local NOON_PROGRESS = 0.5 -- 「昼」にあたる進み具合

-- 効果の部品の組(まとめて持つ)
type Effects = {
	Atmosphere: Atmosphere,
	ColorCorrection: ColorCorrectionEffect,
	Bloom: BloomEffect,
	SunRays: SunRaysEffect,
}

-- 効果1つの後始末の記録。自分で作ったものは Stop で消し、元からあったものは元の値に戻す
type Cleanup = {
	Created: boolean, -- 自分で作ったか
	Instance: Instance,
	Restore: () -> (), -- 元からあったものの値を戻す関数(自分で作ったものでは使わない)
}

-- 元の値(Stop で戻すために覚えておく)
type Originals = {
	ClockTime: number,
	Brightness: number,
	Ambient: Color3,
	OutdoorAmbient: Color3,
}

local effects: Effects? = nil
local cleanups: { Cleanup } = {} -- 4つの効果の後始末の記録
local originals: Originals? = nil
local renderConnection: RBXScriptConnection? = nil
local stateConnection: RBXScriptConnection? = nil

local targetProgress = 0 -- サーバーの知らせから求めた、目標の進み具合
local shownProgress = 0 -- いま見た目に使っている進み具合(なめらかに目標へ近づく)
local appliedProgress = -1 -- 最後に見た目へ反映した進み具合(変化がなければ何もしない)
local resetting = false -- 新しいラウンドで、朝へ速く戻している最中か

-- 数字の補間(t=0 で a、t=1 で b)
local function lerpNumber(a: number, b: number, t: number): number
	return a + (b - a) * t
end

-- 色の補間
local function lerpColor(a: Color3, b: Color3, t: number): Color3
	return a:Lerp(b, t)
end

-- 朝 → 昼 → 夕方 の3点で数字を補間する(進み具合 t が 0.5 のとき、昼の値)
local function lerpThreePoints(morning: number, noon: number, evening: number, t: number): number
	if t < NOON_PROGRESS then
		return lerpNumber(morning, noon, t / NOON_PROGRESS)
	end
	return lerpNumber(noon, evening, (t - NOON_PROGRESS) / (1 - NOON_PROGRESS))
end

-- Lighting 直下から効果を探す。順番:
--   1. 自分の名前(name)で探す(二重に作らない)
--   2. なければ、同じ種類(className)の最初の1つを使う(SeparateEffect の目印があるものは除く)
--      (Studio のテンプレートが、最初から Atmosphere や Bloom を持っていることがあるため。同じ種類を2つ置かない)
--   3. どちらもなければ、名前をつけて作る
-- 戻り値の2つめは「自分で作ったか」
local function findOrCreate(className: string, name: string): (Instance, boolean)
	local byName = Lighting:FindFirstChild(name)
	if byName and byName.ClassName == className then
		return byName, false
	end
	-- 他の部品が専用に作ったもの(SeparateEffect の目印つき。例: 緊張の色補正)は、拾わない
	for _, child in Lighting:GetChildren() do
		if child.ClassName == className and child:GetAttribute("SeparateEffect") ~= true then
			return child, false
		end
	end
	local made = Instance.new(className)
	made.Name = name
	made.Parent = Lighting
	return made, true
end

-- 記録を追加する
local function addCleanup(instance: Instance, created: boolean, restore: () -> ())
	table.insert(cleanups, { Created = created, Instance = instance, Restore = restore })
end

-- 元の値を覚えて、記録に残す(Atmosphere には Enabled がない)
local function getAtmosphere(): Atmosphere
	local instance, created = findOrCreate("Atmosphere", ATMOSPHERE_NAME)
	local atmosphere = instance :: Atmosphere
	local saved = {
		Density = atmosphere.Density,
		Offset = atmosphere.Offset,
		Color = atmosphere.Color,
		Decay = atmosphere.Decay,
		Glare = atmosphere.Glare,
		Haze = atmosphere.Haze,
	}
	addCleanup(atmosphere, created, function()
		atmosphere.Density = saved.Density
		atmosphere.Offset = saved.Offset
		atmosphere.Color = saved.Color
		atmosphere.Decay = saved.Decay
		atmosphere.Glare = saved.Glare
		atmosphere.Haze = saved.Haze
	end)
	return atmosphere
end

local function getColorCorrection(): ColorCorrectionEffect
	local instance, created = findOrCreate("ColorCorrectionEffect", COLOR_CORRECTION_NAME)
	local color = instance :: ColorCorrectionEffect
	local saved = {
		Enabled = color.Enabled,
		Brightness = color.Brightness,
		Contrast = color.Contrast,
		Saturation = color.Saturation,
		TintColor = color.TintColor,
	}
	color.Enabled = true
	addCleanup(color, created, function()
		color.Enabled = saved.Enabled
		color.Brightness = saved.Brightness
		color.Contrast = saved.Contrast
		color.Saturation = saved.Saturation
		color.TintColor = saved.TintColor
	end)
	return color
end

local function getBloom(): BloomEffect
	local instance, created = findOrCreate("BloomEffect", BLOOM_NAME)
	local bloom = instance :: BloomEffect
	local saved = {
		Enabled = bloom.Enabled,
		Intensity = bloom.Intensity,
		Size = bloom.Size,
		Threshold = bloom.Threshold,
	}
	bloom.Enabled = true
	addCleanup(bloom, created, function()
		bloom.Enabled = saved.Enabled
		bloom.Intensity = saved.Intensity
		bloom.Size = saved.Size
		bloom.Threshold = saved.Threshold
	end)
	return bloom
end

local function getSunRays(): SunRaysEffect
	local instance, created = findOrCreate("SunRaysEffect", SUN_RAYS_NAME)
	local sunRays = instance :: SunRaysEffect
	local saved = {
		Enabled = sunRays.Enabled,
		Intensity = sunRays.Intensity,
		Spread = sunRays.Spread,
	}
	sunRays.Enabled = true
	addCleanup(sunRays, created, function()
		sunRays.Enabled = saved.Enabled
		sunRays.Intensity = saved.Intensity
		sunRays.Spread = saved.Spread
	end)
	return sunRays
end

-- 進み具合 t(0〜1)を、Lighting 本体に反映する
local function applyLighting(t: number)
	Lighting.ClockTime = lerpNumber(Config.ClockTimeStart, Config.ClockTimeEnd, t)
	Lighting.Brightness = lerpNumber(Config.LightBrightnessMorning, Config.LightBrightnessEvening, t)
	Lighting.Ambient = lerpColor(Config.LightAmbientMorning, Config.LightAmbientEvening, t)
	Lighting.OutdoorAmbient = lerpColor(Config.LightOutdoorAmbientMorning, Config.LightOutdoorAmbientEvening, t)
end

-- 進み具合 t を、もや(Atmosphere)に反映する
local function applyAtmosphere(atmosphere: Atmosphere, t: number)
	atmosphere.Density = lerpThreePoints(Config.LightAtmoDensityMorning, Config.LightAtmoDensityNoon, Config.LightAtmoDensityEvening, t)
	atmosphere.Haze = lerpThreePoints(Config.LightAtmoHazeMorning, Config.LightAtmoHazeNoon, Config.LightAtmoHazeEvening, t)
	atmosphere.Offset = lerpNumber(Config.LightAtmoOffsetMorning, Config.LightAtmoOffsetEvening, t)
	atmosphere.Color = lerpColor(Config.LightAtmoColorMorning, Config.LightAtmoColorEvening, t)
	atmosphere.Decay = lerpColor(Config.LightAtmoDecayMorning, Config.LightAtmoDecayEvening, t)
	atmosphere.Glare = lerpNumber(Config.LightAtmoGlareMorning, Config.LightAtmoGlareEvening, t)
end

-- 進み具合 t を、色補正・にじみ・光の筋に反映する
local function applyEffects(parts: Effects, t: number)
	local color = parts.ColorCorrection
	color.Brightness = lerpNumber(Config.LightColorBrightnessMorning, Config.LightColorBrightnessEvening, t)
	color.Contrast = lerpNumber(Config.LightColorContrastMorning, Config.LightColorContrastEvening, t)
	color.Saturation = lerpNumber(Config.LightColorSaturationMorning, Config.LightColorSaturationEvening, t)
	color.TintColor = lerpColor(Config.LightColorTintMorning, Config.LightColorTintEvening, t)

	local bloom = parts.Bloom
	bloom.Intensity = lerpNumber(Config.LightBloomIntensityMorning, Config.LightBloomIntensityEvening, t)
	bloom.Size = lerpNumber(Config.LightBloomSizeMorning, Config.LightBloomSizeEvening, t)
	bloom.Threshold = lerpNumber(Config.LightBloomThresholdMorning, Config.LightBloomThresholdEvening, t)

	local sunRays = parts.SunRays
	sunRays.Intensity = lerpNumber(Config.LightSunRaysIntensityMorning, Config.LightSunRaysIntensityEvening, t)
	sunRays.Spread = Config.LightSunRaysSpread
end

local function applyAll(parts: Effects, t: number)
	applyLighting(t)
	applyAtmosphere(parts.Atmosphere, t)
	applyEffects(parts, t)
end

-- 毎フレーム呼ばれる。いまの値を目標へなめらかに近づけ、変わったときだけ反映する
local function onRender(parts: Effects, dt: number)
	local rate = if resetting then Config.LightResetRate else Config.LightSmoothRate
	local alpha = 1 - math.exp(-rate * dt) -- フレームの長さによらず、同じ速さで近づく
	shownProgress += (targetProgress - shownProgress) * alpha
	if math.abs(targetProgress - shownProgress) < Config.LightUpdateEpsilon then
		shownProgress = targetProgress
		resetting = false
	end
	if math.abs(shownProgress - appliedProgress) < Config.LightUpdateEpsilon then
		return
	end
	appliedProgress = shownProgress
	applyAll(parts, math.clamp(shownProgress, 0, 1))
end

-- RoundState を受け取って、目標の進み具合を決める
local function onRoundState(state: unknown, _stageName: unknown, remaining: unknown)
	if typeof(state) ~= "string" or typeof(remaining) ~= "number" then
		return
	end
	if state == "Caught" then
		return -- 捕まった時点の進み具合のまま、変えない
	end
	local newTarget = 1
	if state ~= "Cleared" then
		newTarget = math.clamp(1 - remaining / Config.RoundSeconds, 0, 1)
	end
	if newTarget < targetProgress - Config.LightResetDropThreshold then
		resetting = true -- 大きく下がった = 新しいラウンド。朝へ速く戻す
	end
	targetProgress = newTarget
end

-- 元の値を覚える
local function saveOriginals(): Originals
	return {
		ClockTime = Lighting.ClockTime,
		Brightness = Lighting.Brightness,
		Ambient = Lighting.Ambient,
		OutdoorAmbient = Lighting.OutdoorAmbient,
	}
end

function LightingController.Start()
	if renderConnection then
		return -- 二重に起動しない
	end
	local found = ReplicatedStorage:WaitForChild(Config.RoundStateRemoteName, Config.LightEffectWaitSeconds)
	if not found or not found:IsA("RemoteEvent") then
		warn(`[LightingController] {Config.RoundStateRemoteName} が見つかりません。光は変わりません。`)
		return
	end

	originals = saveOriginals()
	local parts: Effects = {
		Atmosphere = getAtmosphere(),
		ColorCorrection = getColorCorrection(),
		Bloom = getBloom(),
		SunRays = getSunRays(),
	}
	effects = parts

	applyAll(parts, 0) -- 最初は朝の状態から
	appliedProgress = 0
	stateConnection = found.OnClientEvent:Connect(onRoundState)
	renderConnection = RunService.RenderStepped:Connect(function(dt: number)
		onRender(parts, dt)
	end)
end

-- 止めて、元の値に戻す(このゲームでは普段は呼ばない)
function LightingController.Stop()
	if renderConnection then
		renderConnection:Disconnect()
		renderConnection = nil
	end
	if stateConnection then
		stateConnection:Disconnect()
		stateConnection = nil
	end
	local saved = originals
	if saved then
		Lighting.ClockTime = saved.ClockTime
		Lighting.Brightness = saved.Brightness
		Lighting.Ambient = saved.Ambient
		Lighting.OutdoorAmbient = saved.OutdoorAmbient
	end
	for _, cleanup in cleanups do
		if cleanup.Created then
			cleanup.Instance:Destroy() -- 自分で作ったものだけ消す
		else
			cleanup.Restore() -- 元からあったものは、元の値に戻す
		end
	end
	table.clear(cleanups)
	effects = nil
	originals = nil
	targetProgress = 0
	shownProgress = 0
	appliedProgress = -1
	resetting = false
end

return LightingController
