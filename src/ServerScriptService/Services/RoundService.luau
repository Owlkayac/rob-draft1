--!strict
-- ラウンド(1回の遊び)の進行をサーバーで管理する部品。仕様書 003 と 004 の 3・4。
-- 経過時間・段階・クリアと失敗の判定は、すべてサーバーが行う。
-- クライアントには、表示用に状態を知らせるだけ。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local CrayfishService = require(script.Parent.CrayfishService)
local FieldService = require(script.Parent.FieldService)

-- ラウンドの状態の名前
type RoundStateName = "Playing" | "Caught" | "Cleared"

-- プレイヤー1人ぶんのラウンドの状態
type PlayerRound = {
	State: RoundStateName,
	StartedAt: number, -- ラウンドを始めた時刻(os.clock)
	Stage: number, -- 稲の段階(1〜3。クリアしたら最後の番号)
	Remaining: number, -- 残り秒数(終わったあとの表示用に覚えておく)
	LastRestartAt: number, -- 最後に「もう一度」を受け付けた時刻(os.clock)
}

local RoundService = {}

-- Player をキーにした状態の表(将来、複数人でも動くように)
local rounds: { [Player]: PlayerRound } = {}
-- 稲の見た目は田んぼ全体で1つ。一人用の間は、いちばん新しく始めたラウンドの人に合わせる
local latestPlayer: Player? = nil
-- 「やり直すとき」に呼んでほしい関数(天敵の担当が登録する)
local restartCallbacks: { () -> () } = {}
local stateRemote: RemoteEvent? = nil

local function newRound(): PlayerRound
	return {
		State = "Playing",
		StartedAt = os.clock(),
		Stage = 1,
		Remaining = Config.RoundSeconds,
		LastRestartAt = -math.huge,
	}
end

local function getStageName(stage: number): string
	return Config.StageNames[stage] or ""
end

-- 経過時間から、稲の段階(1〜3)を計算する
local function calcStage(elapsed: number): number
	local stage = 1
	for index, seconds in Config.GrowthStageSeconds do
		if elapsed >= seconds then
			stage = index + 1
		end
	end
	return stage
end

local function calcRemaining(elapsed: number): number
	return math.max(0, math.ceil(Config.RoundSeconds - elapsed))
end

-- クライアントに、いまの状態を送る(状態、段階の名前、残り秒数)
local function sendState(player: Player, round: PlayerRound)
	local remote = stateRemote
	if remote then
		remote:FireClient(player, round.State, getStageName(round.Stage), round.Remaining)
	end
end

local function getHumanoid(player: Player): Humanoid?
	local character = player.Character
	if not character then
		return nil
	end
	return character:FindFirstChildOfClass("Humanoid")
end

-- ラウンドを終える(Caught か Cleared にして、動けなくする)
local function finishRound(player: Player, round: PlayerRound, newState: RoundStateName)
	local elapsed = os.clock() - round.StartedAt
	round.State = newState
	if newState == "Cleared" then
		round.Remaining = 0
		round.Stage = #Config.StageNames -- 「稲刈りの日」
	else
		round.Remaining = calcRemaining(elapsed)
	end

	-- 先に生存を外し(潜っていたら浮上する)、そのあとで歩く速さを0にする
	CrayfishService.SetAlive(player, false)
	local humanoid = getHumanoid(player)
	if humanoid then
		humanoid.WalkSpeed = 0
	end
	sendState(player, round)
end

-- つかまった(天敵や、死んだときに呼ぶ)。Playing でなければ何もしない。
-- 使う関数(onCharacterAdded)より上に定義し、あとで RoundService に公開する
local function notifyCaught(player: Player)
	local round = rounds[player]
	if not round or round.State ~= "Playing" then
		return
	end
	finishRound(player, round, "Caught")
end
RoundService.NotifyCaught = notifyCaught

-- ラウンドを始める(キャラクターが生まれたとき)
local function startRound(player: Player)
	local round = rounds[player]
	if not round then
		return
	end
	round.State = "Playing"
	round.StartedAt = os.clock()
	round.Stage = 1
	round.Remaining = Config.RoundSeconds
	latestPlayer = player
	FieldService.SetGrowthStage(1)
	sendState(player, round)
end

local function onCharacterAdded(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	if player.Character ~= character then
		return -- 待っている間に、別のキャラクターに変わった
	end
	startRound(player)
	humanoid.Died:Connect(function()
		notifyCaught(player)
	end)
end

-- 1秒ごとの更新:Playing 中の人の段階を計算し、クリア判定と通知をする
local function updateRounds()
	for player, round in rounds do
		if round.State == "Playing" then
			local elapsed = os.clock() - round.StartedAt
			if elapsed >= Config.RoundSeconds then
				finishRound(player, round, "Cleared")
			else
				round.Stage = calcStage(elapsed)
				round.Remaining = calcRemaining(elapsed)
				sendState(player, round)
			end
			-- 稲の見た目は、いちばん新しく始めた人の段階に合わせる(変わったときだけ作業される)
			if player == latestPlayer and round.State == "Playing" then
				FieldService.SetGrowthStage(round.Stage)
			end
		end
	end
end

-- 「もう一度」のお願いを確認して、やり直す
local function onRestartRequest(player: Player, ...: unknown)
	local round = rounds[player] -- (a) 状態があるか
	if not round then
		return
	end
	if select("#", ...) ~= 0 then -- (b) 値なしのはず
		return
	end
	if round.State == "Playing" then -- (c) Caught か Cleared のときだけ
		return
	end
	local now = os.clock()
	if now - round.LastRestartAt < Config.RestartRequestMinInterval then -- (d) 連打
		return
	end
	round.LastRestartAt = now

	FieldService.SetGrowthStage(1) -- 稲を最初に戻す
	for _, callback in restartCallbacks do -- 天敵などを最初に戻す
		task.spawn(callback)
	end
	-- 生まれ直す。キャラクター生成の処理(onCharacterAdded)で、新しいラウンドが始まる
	task.spawn(function()
		local ok, err = pcall(function()
			player:LoadCharacter()
		end)
		if not ok then
			warn(`[RoundService] LoadCharacter に失敗しました: {err}`)
		end
	end)
end

local function onPlayerAdded(player: Player)
	if rounds[player] then
		return
	end
	rounds[player] = newRound()
	player.CharacterAdded:Connect(function(character: Model)
		onCharacterAdded(player, character)
	end)
	if player.Character then
		task.spawn(onCharacterAdded, player, player.Character)
	end
end

function RoundService.Start()
	local stateEvent = Instance.new("RemoteEvent")
	stateEvent.Name = Config.RoundStateRemoteName
	stateEvent.Parent = ReplicatedStorage
	stateRemote = stateEvent

	local restartEvent = Instance.new("RemoteEvent")
	restartEvent.Name = Config.RestartRemoteName
	restartEvent.Parent = ReplicatedStorage
	restartEvent.OnServerEvent:Connect(onRestartRequest)

	-- 死んだあとに勝手に生まれ直すと、「もう一度」を押さずに次のラウンドが始まってしまうので止める
	pcall(function()
		Players.RespawnTime = Config.RespawnBlockSeconds
	end)

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(function(player: Player)
		rounds[player] = nil
		if latestPlayer == player then
			latestPlayer = nil
		end
	end)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end

	task.spawn(function()
		while true do
			task.wait(Config.RoundTickSeconds)
			updateRounds()
		end
	end)
end

-- いま遊んでいる(Playing)か
function RoundService.IsPlaying(player: Player): boolean
	local round = rounds[player]
	return round ~= nil and round.State == "Playing"
end

-- いまの段階の、天敵の発見距離の倍率。プレイヤーがいなければ 1.0
function RoundService.GetSightMultiplier(player: Player): number
	local round = rounds[player]
	if not round then
		return 1.0
	end
	local index = math.clamp(round.Stage, 1, #Config.SightMultipliers)
	return Config.SightMultipliers[index]
end

-- いまの稲の段階(プレイヤーがいなければ 1)
function RoundService.GetStage(player: Player): number
	local round = rounds[player]
	if not round then
		return 1
	end
	return round.Stage
end

-- やり直しのときに呼ぶ関数を登録する(天敵を最初に戻すため)
function RoundService.OnRestart(callback: () -> ())
	table.insert(restartCallbacks, callback)
end

return RoundService
