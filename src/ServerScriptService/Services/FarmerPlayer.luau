--!strict
-- 農家さんモード(仕様書 016)で、プレイヤーのキャラクターを「巨人の農家さん」にする部品。
-- やること:
--   Apply(player, character): 歩く速さ・ジャンプ禁止、カメラのズーム距離、巨人の大きさ(ScaleTo)、麦わら帽子。
--   Reset(player): カメラのズーム距離を元に戻す(巨人のキャラクターは、生まれ直すと新しいキャラクターになるので、戻すのはズームだけ)。
--   GetScale(player): いま実際に巨人になっている倍率(まだ・失敗したときは 1)。つかまえる距離の計算に使う。
-- プレイヤーごとの状態は、Player をキーにした表で持つ(将来、複数人でも動くように)。
-- 人型の見た目はそのまま(帽子だけ足す)。ザリガニの見た目・ジャンプ・潜る・ジェットは、農家さんモードでは使わない。
-- この部品は RoundService などを読み込まない(RoundService が、この部品を呼ぶ。循環 require を防ぐ)。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Config = require(ReplicatedStorage.Shared.Config)
local WarnOnce = require(script.Parent.Enemy.WarnOnce)

-- 帽子を作る部品は ServerStorage/Modules にある(Rojo の対応は default.project.json)
local modulesFolder = ServerStorage:WaitForChild("Modules", 10)
assert(modulesFolder, "[FarmerPlayer] ServerStorage/Modules が見つかりません")
local farmerModelScript = modulesFolder:WaitForChild("FarmerModel", 10)
assert(farmerModelScript, "[FarmerPlayer] FarmerModel が見つかりません")
local FarmerModel = require(farmerModelScript :: ModuleScript)

local MIN_POSITIVE = 0.001 -- 待ち時間の下限(秒)。Config が 0 でも、busy loop(待ちなしの繰り返し)にならないように

-- プレイヤー1人ぶんの状態
type FarmerState = {
	Token: number, -- 古い待ち(服の読み込みを待っている処理)を無効にするための番号
	Scale: number, -- いま実際に巨人になっている倍率(まだ・失敗なら 1)
	Applied: boolean, -- 巨人にできたか
	SavedMin: number?, -- 元のズーム距離(近い側)。Apply が覚え、Reset が戻す
	SavedMax: number?, -- 元のズーム距離(遠い側)
}

local FarmerPlayer = {}

-- Player をキーにした状態の表
local states: { [Player]: FarmerState } = {}

local function getState(player: Player): FarmerState
	local state = states[player]
	if state == nil then
		state = {
			Token = 0,
			Scale = 1,
			Applied = false,
			SavedMin = nil,
			SavedMax = nil,
		}
		states[player] = state
	end
	return state
end

-- ===== カメラのズーム距離 =====

-- ズーム距離を設定する。近い側が遠い側を超えないように、順番に気をつける。失敗してもエラーにしない
local function setZoom(player: Player, minDistance: number, maxDistance: number)
	local low = math.min(minDistance, maxDistance)
	local high = math.max(minDistance, maxDistance)
	local ok, err = pcall(function()
		if high >= player.CameraMaxZoomDistance then
			player.CameraMaxZoomDistance = high -- 広げるときは、遠い側から
			player.CameraMinZoomDistance = low
		else
			player.CameraMinZoomDistance = low -- 狭めるときは、近い側から
			player.CameraMaxZoomDistance = high
		end
	end)
	if not ok then
		WarnOnce.Warn("FarmerPlayerZoom", `[FarmerPlayer] カメラのズーム距離を変えられませんでした: {err}`)
	end
end

-- Roblox の標準のズーム距離(StarterPlayer の値。読めなければ Config の標準値)
local function getDefaultZoom(): (number, number)
	local ok, minValue, maxValue = pcall(function(): (number, number)
		return StarterPlayer.CameraMinZoomDistance, StarterPlayer.CameraMaxZoomDistance
	end)
	if ok and type(minValue) == "number" and type(maxValue) == "number" then
		return minValue, maxValue
	end
	return Config.DefaultCameraMinZoom, Config.DefaultCameraMaxZoom
end

-- 巨人用のズーム距離にする。元の値は、まだ覚えていなければ、いまの値を覚える
local function applyZoom(player: Player, state: FarmerState)
	if state.SavedMin == nil or state.SavedMax == nil then
		state.SavedMin = player.CameraMinZoomDistance
		state.SavedMax = player.CameraMaxZoomDistance
	end
	setZoom(player, Config.FarmerPlayerCameraMin, Config.FarmerPlayerCameraMax)
end

-- ===== 巨人にする =====

-- 歩く速さ・ジャンプ禁止など、Humanoid の設定(すぐできるもの)
local function setupHumanoid(character: Model)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		WarnOnce.Warn("FarmerPlayerNoHumanoid", "[FarmerPlayer] Humanoid が見つからないので、歩く速さを決められません")
		return
	end
	humanoid.WalkSpeed = Config.FarmerPlayerWalkSpeed
	humanoid.UseJumpPower = true
	humanoid.JumpPower = 0 -- ジャンプ禁止
	humanoid.BreakJointsOnDeath = false -- 死んだときに、体がばらばらにならないように
end

-- 待っている間に、やり直し・メニュー戻り・生まれ直し・退出で、状況が変わっていないか
local function isCurrent(player: Player, character: Model, token: number): boolean
	local state = states[player]
	return state ~= nil and state.Token == token and player.Parent ~= nil and player.Character == character and character.Parent ~= nil
end

-- 服や髪が読み込まれるのを待つ(最大 Config.FarmerPlayerAppearanceWaitSeconds)。まだ有効なキャラクターなら true。
-- 終わりの条件は、次のうち、どれか早いもの:
--   ・player:HasAppearanceLoaded() が true(すでに読み込み済み)
--   ・player.CharacterAppearanceLoaded のイベントが来た(このキャラクターのものだけ数える)
--   ・最大の待ち時間が過ぎた
-- 先に大きくしてから服が付くと、服の大きさが合わないことがあるので、読み込んだあとで巨人にする
local function waitForAppearance(player: Player, character: Model, token: number): boolean
	local eventLoaded = false
	local connection = player.CharacterAppearanceLoaded:Connect(function(loadedCharacter: Model)
		if loadedCharacter == character and player.Character == character then
			eventLoaded = true
		end
	end)
	local deadline = os.clock() + Config.FarmerPlayerAppearanceWaitSeconds
	while isCurrent(player, character, token) do
		local ok, loaded = pcall(function(): boolean
			return player:HasAppearanceLoaded()
		end)
		if eventLoaded or not ok or loaded or os.clock() >= deadline then
			break
		end
		task.wait(math.max(Config.FarmerPlayerAppearancePollSeconds, MIN_POSITIVE))
	end
	connection:Disconnect() -- どの終わり方でも、つなぎを切る
	return isCurrent(player, character, token)
end

-- キャラクターを Config.FarmerScale 倍にする。戻り値は、実際の倍率(失敗したら 1)
local function scaleCharacter(character: Model): number
	local ok, err = pcall(function()
		character:ScaleTo(Config.FarmerScale)
	end)
	if not ok then
		WarnOnce.Warn("FarmerPlayerScale", `[FarmerPlayer] 巨人にできませんでした(標準の大きさのままにします): {err}`)
		return 1
	end
	local readOk, scale = pcall(function(): number
		return character:GetScale()
	end)
	if readOk and type(scale) == "number" and scale > 0 then
		return scale
	end
	return Config.FarmerScale
end

-- 大きくしたあと、足がゆかにめり込まないように、足元の高さを合わせる(上にずらすだけ。下げはしない)
local function liftAboveFloor(character: Model)
	local ok, err = pcall(function()
		local targetFootY = Config.FieldFloorTopY + Config.FarmerPlayerSpawnLift
		local diff = targetFootY - FarmerModel.GetFootY(character)
		if diff > 0 then
			character:PivotTo(character:GetPivot() + Vector3.new(0, diff, 0))
		end
	end)
	if not ok then
		WarnOnce.Warn("FarmerPlayerLift", `[FarmerPlayer] 足元の高さを合わせられませんでした: {err}`)
	end
end

-- 服の読み込みを待ってから、巨人にして、麦わら帽子をつける
local function growAndDress(player: Player, character: Model, token: number)
	if not waitForAppearance(player, character, token) then
		return
	end
	local scale = scaleCharacter(character)
	liftAboveFloor(character)
	local head = character:FindFirstChild("Head")
	if head ~= nil and head:IsA("BasePart") then
		FarmerModel.AddHat(head, scale)
	else
		WarnOnce.Warn("FarmerPlayerNoHead", "[FarmerPlayer] Head が見つからないので、帽子をつけられません")
	end
	local state = states[player]
	if state ~= nil and state.Token == token then
		state.Scale = scale
		state.Applied = true
	end
end

-- キャラクターを、巨人の農家さんにする(農家さんのラウンドが始まるとき、RoundService が呼ぶ)。
-- すぐやること: 歩く速さ・ジャンプ禁止・カメラのズーム距離。
-- 少し待ってからやること: 巨人の大きさ(ScaleTo)と麦わら帽子(服の読み込みのあと)
function FarmerPlayer.Apply(player: Player, character: Model)
	local state = getState(player)
	state.Token += 1 -- 前の待ちを無効にする
	local token = state.Token
	state.Scale = 1
	state.Applied = false

	applyZoom(player, state)
	setupHumanoid(character)
	task.spawn(function()
		local ok, err = pcall(growAndDress, player, character, token)
		if not ok then
			WarnOnce.Warn("FarmerPlayerGrow", `[FarmerPlayer] 巨人にする処理でエラーが出ました: {err}`)
		end
	end)
end

-- ズーム距離を元に戻す(メニューに戻るとき・ザリガニで始めるとき・メニュー待ちのとき)。何回呼んでも安全。
-- 巨人の大きさは、キャラクターが生まれ直すと新しいキャラクターになるので、ここでは戻さない
function FarmerPlayer.Reset(player: Player)
	local state = states[player]
	if state == nil then
		return -- 一度も農家さんになっていない
	end
	state.Token += 1 -- 待っている処理を無効にする
	state.Scale = 1
	state.Applied = false
	local savedMin = state.SavedMin
	local savedMax = state.SavedMax
	if savedMin == nil or savedMax == nil then
		return -- ズームを変えていない(戻すものがない)
	end
	state.SavedMin = nil
	state.SavedMax = nil
	local defaultMin, defaultMax = getDefaultZoom()
	-- 覚えていた値が使えなければ(数字でない・並びがおかしい)標準の値にする
	if type(savedMin) ~= "number" or type(savedMax) ~= "number" or savedMin > savedMax then
		savedMin, savedMax = defaultMin, defaultMax
	end
	setZoom(player, savedMin, savedMax)
end

-- いま実際に巨人になっている倍率。まだ(服の読み込み待ち)・失敗・農家さんでないときは 1
function FarmerPlayer.GetScale(player: Player): number
	local state = states[player]
	if state == nil or not state.Applied then
		return 1
	end
	return state.Scale
end

Players.PlayerRemoving:Connect(function(player: Player)
	states[player] = nil
end)

return FarmerPlayer
