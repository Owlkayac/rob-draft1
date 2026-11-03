--!strict
-- 効果音・環境音を鳴らす(仕様書 011)。クライアント(自分の端末)だけで鳴らす。
-- 音のID(Config.SoundIds)が空・形が正しくない種類は、Sound を作らない。鳴らさない。エラーも警告も出さない。
-- 新しい通信は足さない。RoundState は、ほかの部品とは別に、自分でつなぐ。
-- 毎フレームの処理はしない。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config") :: ModuleScript)
local SoundUtil = require(Shared:WaitForChild("SoundUtil") :: ModuleScript)

local SoundController = {}

local HIDDEN_ATTRIBUTE = "Hidden" -- 潜っているとき、サーバーがキャラクターにつける目印
local JETTING_ATTRIBUTE = "Jetting" -- ジェット噴射中、サーバーがキャラクターにつける目印(仕様書 013)
local STATE_MENU = "Menu" -- スタートメニューの間(仕様書 015)
local STATE_PLAYING = "Playing"
local STATE_CAUGHT = "Caught"
local STATE_CLEARED = "Cleared"

-- 作る音の種類(Config.SoundIds のキーと同じ名前)
local SOUND_NAMES = { "Ambient", "Splash", "Jet", "Eat", "Caught", "Clear" }

local sounds: { [string]: Sound } = {} -- 種類 → Sound(IDが有効な種類だけ入る)
local started = false
local lastState: string? = nil -- 最後に受け取った RoundState の状態(同じ状態の通知で、くり返さないため)
local ambientDucked = false -- 環境音を小さくしている最中か
local ambientTween: Tween? = nil
local hiddenConnection: RBXScriptConnection? = nil -- 今のキャラクターの Hidden を見るつなぎ
local jettingConnection: RBXScriptConnection? = nil -- 今のキャラクターの Jetting を見るつなぎ
local lastJetting = false -- 前に見た Jetting の値(false から true に変わったときだけ Jet を鳴らすため)
local lastHidden = false -- 前に見た Hidden の値(実際に変わったときだけ Splash を鳴らすため。無い値は false 扱い)

-- 生きている Sound を返す。作っていない・消えた(Parent がない)ときは nil
local function getSound(name: string): Sound?
	local sound = sounds[name]
	if sound == nil or sound.Parent == nil then
		return nil
	end
	return sound
end

-- 1回鳴らす(最初から)。音が無ければ何もしない
local function playOnce(name: string)
	local sound = getSound(name)
	if sound == nil then
		return
	end
	sound.TimePosition = 0
	sound:Play()
end

-- IDが有効な種類の Sound を、SoundService の下に1つずつ作る
local function createSounds()
	for _, name in SOUND_NAMES do
		local soundId = SoundUtil.GetId(name)
		if soundId ~= nil then
			local sound = Instance.new("Sound")
			sound.Name = "Sound_" .. name
			sound.SoundId = soundId
			sound.Volume = SoundUtil.GetVolume(name)
			sound.Looped = (name == "Ambient")
			sound.Parent = SoundService
			sounds[name] = sound
		end
	end
end

-- 環境音の音量を、なめらかに変える(古い動きは止める)
local function tweenAmbientVolume(sound: Sound, volume: number)
	local old = ambientTween
	if old then
		old:Cancel()
	end
	local tween = TweenService:Create(sound, TweenInfo.new(Config.SoundAmbientDuckSeconds), { Volume = volume })
	ambientTween = tween
	tween:Play()
end

-- Playing:環境音を鳴らす(まだなら始める)。小さくしていたら、元の音量へ戻す
local function onPlaying()
	local ambient = getSound("Ambient")
	if ambient == nil then
		return
	end
	if not ambient.Playing then
		ambient:Play()
	end
	if ambientDucked then
		ambientDucked = false
		tweenAmbientVolume(ambient, SoundUtil.GetVolume("Ambient"))
	end
end

-- Menu:環境音を止める(メニューの間は鳴らさない)。次の Playing で、元の音量で鳴らし直す。
-- Caught・Clear の効果音は鳴らさない
local function onMenu()
	local ambient = getSound("Ambient")
	if ambient == nil then
		return
	end
	local old = ambientTween
	if old then
		old:Cancel()
		ambientTween = nil
	end
	if ambient.Playing then
		ambient:Stop()
	end
	if ambientDucked then
		ambientDucked = false
		ambient.Volume = SoundUtil.GetVolume("Ambient") -- 小さくしていた音量を、元に戻しておく
	end
end

-- Caught・Cleared:環境音を小さくする
local function duckAmbient()
	local ambient = getSound("Ambient")
	if ambient == nil or ambientDucked then
		return
	end
	ambientDucked = true
	tweenAmbientVolume(ambient, math.clamp(Config.SoundAmbientDuckVolume, 0, 1))
end

-- RoundState を受け取る。状態が「変わったとき」だけ、Caught・Clear を1回鳴らす。
-- Menu は、サーバーが毎秒くり返し送ってくる(取りこぼし対策)ので、何回来ても安全な作りにしてある
local function onRoundState(state: unknown, _stageName: unknown, _remaining: unknown)
	if typeof(state) ~= "string" then
		return
	end
	local newState = state :: string
	if newState == STATE_MENU then
		onMenu()
	elseif newState == STATE_PLAYING then
		onPlaying()
	elseif newState == STATE_CAUGHT or newState == STATE_CLEARED then
		duckAmbient()
		if newState ~= lastState then
			playOnce(if newState == STATE_CAUGHT then "Caught" else "Clear")
		end
	end
	lastState = newState -- Playing に戻れば、次の Caught・Clear をまた鳴らせる
end

-- 古い Hidden の見張りを切る
local function disconnectHidden()
	local connection = hiddenConnection
	hiddenConnection = nil
	if connection then
		connection:Disconnect()
	end
end

-- 古い Jetting の見張りを切る
local function disconnectJetting()
	local connection = jettingConnection
	jettingConnection = nil
	if connection then
		connection:Disconnect()
	end
end

-- キャラクターができたら、Jetting の変化(噴射の始まり)を見張る。最初の値は、鳴らさずに覚えるだけ
local function watchJetting(character: Model)
	disconnectJetting()
	lastJetting = character:GetAttribute(JETTING_ATTRIBUTE) == true
	jettingConnection = character:GetAttributeChangedSignal(JETTING_ATTRIBUTE):Connect(function()
		local value = character:GetAttribute(JETTING_ATTRIBUTE) == true
		if value == lastJetting then
			return -- 実際には変わっていない
		end
		lastJetting = value
		if value then
			playOnce("Jet") -- false から true になったときだけ、1回鳴らす
		end
	end)
end

-- キャラクターができたら、Hidden の変化(潜る・浮上)を見張る。生まれ直すたびに、つなぎ直す。
-- 値が実際に変わったときだけ Splash を鳴らす。最初の値は、鳴らさずに覚えるだけ
local function watchCharacter(character: Model)
	watchJetting(character)
	disconnectHidden()
	lastHidden = character:GetAttribute(HIDDEN_ATTRIBUTE) == true -- 生まれ直したので、覚え直す(鳴らさない)
	hiddenConnection = character:GetAttributeChangedSignal(HIDDEN_ATTRIBUTE):Connect(function()
		local value = character:GetAttribute(HIDDEN_ATTRIBUTE) == true
		if value == lastHidden then
			return -- 実際には変わっていない
		end
		lastHidden = value
		playOnce("Splash")
	end)
end

-- 餌を食べたときの音(仕様書 012 で、ScoreState から呼ぶ)。ID が空なら何もしない
function SoundController.PlayEat()
	playOnce("Eat")
end

function SoundController.Start()
	if started then
		return -- 二重に起動しない
	end
	started = true
	createSounds()
	if next(sounds) == nil then
		return -- 鳴らす音がひとつもない(ID がすべて空)。何もしない
	end

	local player = Players.LocalPlayer
	player.CharacterAdded:Connect(watchCharacter)
	local existing = player.Character
	if existing then
		watchCharacter(existing)
	end

	-- 餌を食べた音(仕様書 012)。RoundState とは別に、自分でつなぐ(待っても、ほかを止めない)
	task.spawn(function()
		local scoreFound = ReplicatedStorage:WaitForChild(Config.ScoreStateRemoteName, Config.SoundWaitSeconds)
		if not scoreFound or not scoreFound:IsA("RemoteEvent") then
			warn(`[SoundController] {Config.ScoreStateRemoteName} が見つかりません。餌を食べた音は鳴りません。`)
			return
		end
		scoreFound.OnClientEvent:Connect(function(_score: unknown, _best: unknown, _newBest: unknown, eaten: unknown)
			if eaten == true then
				SoundController.PlayEat()
			end
		end)
	end)

	local found = ReplicatedStorage:WaitForChild(Config.RoundStateRemoteName, Config.SoundWaitSeconds)
	if not found or not found:IsA("RemoteEvent") then
		warn(`[SoundController] {Config.RoundStateRemoteName} が見つかりません。環境音・つかまった音・クリア音は鳴りません。`)
		return
	end
	found.OnClientEvent:Connect(onRoundState)
end

return SoundController
