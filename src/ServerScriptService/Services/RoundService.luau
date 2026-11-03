--!strict
-- ラウンド(1回の遊び)の進行をサーバーで管理する部品。仕様書 003 と 004 の 3・4。
-- 経過時間・段階・クリアと失敗の判定は、すべてサーバーが行う。
-- クライアントには、表示用に状態を知らせるだけ。
-- 仕様書 015:ラウンドを始めるのは、メニューで「スタート」を押した(フェーズが Playing の)ときだけ。
--   メニューにいる間は、動けない状態で待つ(State = "Menu")。メニューの内容は SetupService が持つ。
-- 仕様書 016(農家さんモード):やくわりが "Farmer" のラウンドは、プレイヤーが巨人の農家さんになり、AIのザリガニをつかまえる。
--   ・時間切れ(RoundSeconds)は、"Caught"(にげられた)として終わる。ぜんぶつかまえたら、NotifyAllPreyCaught で、すぐ "Cleared" で終わる。
--   ・AIのザリガニ(PreyService)は、この部品を呼ぶ側。この部品は PreyService を読み込まない(循環 require を防ぐ)。
--     代わりに、OnRoundStart・OnRoundEnd に関数を登録してもらい、ラウンドの始まりと終わりを知らせる。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local CrayfishService = require(script.Parent.CrayfishService)
local FarmerPlayer = require(script.Parent.FarmerPlayer)
local FieldService = require(script.Parent.FieldService)
local WarnOnce = require(script.Parent.Enemy.WarnOnce)
local ScoreService = require(script.Parent.ScoreService)
local SetupService = require(script.Parent.SetupService)

-- ラウンドの状態の名前("Menu" = メニュー待ち。ゲームは始まっていない)
type RoundStateName = "Menu" | "Playing" | "Caught" | "Cleared"

-- プレイヤー1人ぶんのラウンドの状態
type PlayerRound = {
	State: RoundStateName,
	StartedAt: number, -- ラウンドを始めた時刻(os.clock)
	Stage: number, -- 稲の段階(1〜3。クリアしたら最後の番号)
	Remaining: number, -- 残り秒数(終わったあとの表示用に覚えておく)
	LastRestartAt: number, -- 最後に「もう一度」を受け付けた時刻(os.clock)
	StuckSince: number?, -- フェーズが Playing なのに、State が Menu のままになっているのを、最初に見た時刻(os.clock)。なければ nil(保険の見張り用)
}

local RoundService = {}

-- Player をキーにした状態の表(将来、複数人でも動くように)
local rounds: { [Player]: PlayerRound } = {}
-- 稲の見た目は田んぼ全体で1つ。一人用の間は、いちばん新しく始めたラウンドの人に合わせる
local latestPlayer: Player? = nil
-- 稲の見た目を最後に更新した時刻(os.clock)と、そのときの段階。RiceGrowthUpdateSeconds ごとに更新する
local lastRiceUpdateAt = 0
local lastRiceStage = 1
-- 「やり直すとき」に呼んでほしい関数(天敵・餌・AIザリガニの担当が登録する)
local restartCallbacks: { () -> () } = {}
-- 「ラウンドが始まったとき」(引数:プレイヤー、やくわり)と「終わったとき」(引数:プレイヤー、やくわり、終わり方 "Caught" か "Cleared")に呼んでほしい関数
local roundStartCallbacks: { (Player, string) -> () } = {}
local roundEndCallbacks: { (Player, string, string) -> () } = {}
local stateRemote: RemoteEvent? = nil

local function newRound(): PlayerRound
	return {
		State = "Menu", -- 入った直後は、メニュー待ち(「スタート」を押すまで、ラウンドは始まらない)
		StartedAt = os.clock(),
		Stage = 1,
		Remaining = Config.RoundSeconds,
		LastRestartAt = -math.huge,
		StuckSince = nil,
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

-- クライアントに、メニュー待ちであることを知らせる(引数の形は、ほかの状態と同じ)
local function sendMenuState(player: Player)
	local remote = stateRemote
	if remote then
		remote:FireClient(player, "Menu", "", 0)
	end
end

local function getHumanoid(player: Player): Humanoid?
	local character = player.Character
	if not character then
		return nil
	end
	return character:FindFirstChildOfClass("Humanoid")
end

-- 登録された関数を、別のスレッドで呼ぶ。1つがエラーでも、ほかは呼ぶ
local function fireRoundStart(player: Player, role: string)
	for _, callback in roundStartCallbacks do
		task.spawn(function()
			local ok, err = pcall(callback, player, role)
			if not ok then
				warn(`[RoundService] ラウンド開始の関数でエラーが出ました: {err}`)
			end
		end)
	end
end

local function fireRoundEnd(player: Player, role: string, endState: string)
	for _, callback in roundEndCallbacks do
		task.spawn(function()
			local ok, err = pcall(callback, player, role, endState)
			if not ok then
				warn(`[RoundService] ラウンド終了の関数でエラーが出ました: {err}`)
			end
		end)
	end
end

-- ラウンドを終える(Caught か Cleared にして、動けなくする)。
-- ザリガニのクリアは「稲刈りの日まで生き延びた」(稲を育ちきった見た目にする)。
-- 農家さんのクリアは「ぜんぶつかまえた」(途中で終わるので、稲・段階・残り時間は、そのまま)
local function finishRound(player: Player, round: PlayerRound, newState: RoundStateName)
	local elapsed = os.clock() - round.StartedAt
	local role = SetupService.GetRole(player)
	round.State = newState
	if newState == "Cleared" and role ~= "Farmer" then
		round.Remaining = 0
		round.Stage = #Config.StageNames -- 「稲刈りの日」
		if player == latestPlayer then
			FieldService.SetGrowthProgress(1) -- 稲を育ちきった見た目にする
		end
	else
		round.Remaining = calcRemaining(elapsed)
	end

	-- 点数を確定する(結果の画面に使うので、RoundState を送る前に)。クリアのときは、経過を RoundSeconds までにする
	ScoreService.Tick(player, math.min(elapsed, Config.RoundSeconds))
	ScoreService.EndRound(player, newState == "Cleared")

	-- 先に生存を外し(潜っていたら浮上する)、そのあとで歩く速さを0にする
	CrayfishService.SetAlive(player, false)
	local humanoid = getHumanoid(player)
	if humanoid then
		humanoid.WalkSpeed = 0
	end
	SetupService.SetCanReturnToMenu(player, true) -- 結果の画面:「メニューへ」を押せる
	sendState(player, round)
	fireRoundEnd(player, role, newState) -- AIザリガニを消す、など
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

-- AIのザリガニを、ぜんぶつかまえた(PreyService から呼ばれる。農家さんのラウンドで、Playing のときだけ有効)。
-- すぐ "Cleared" で終わらせる
local function notifyAllPreyCaught(player: Player)
	local round = rounds[player]
	if not round or round.State ~= "Playing" then
		return
	end
	if SetupService.GetRole(player) ~= "Farmer" then
		return
	end
	finishRound(player, round, "Cleared")
end
RoundService.NotifyAllPreyCaught = notifyAllPreyCaught

-- ラウンドを始める(キャラクターが生まれたとき)
local function startRound(player: Player)
	local round = rounds[player]
	if not round then
		return
	end
	round.State = "Playing"
	round.StuckSince = nil -- ラウンドが始まったので、見張りの時計をリセットする
	round.StartedAt = os.clock()
	round.Stage = 1
	round.Remaining = Config.RoundSeconds
	latestPlayer = player
	SetupService.SetCanReturnToMenu(player, false)
	FieldService.ResetRice() -- 稲を最初の状態(刈り株も元に戻す)にする
	lastRiceUpdateAt = os.clock()
	lastRiceStage = 1
	ScoreService.BeginRound(player) -- 点数を0に戻す(RoundState より先)
	sendState(player, round)
end

-- メニュー待ちにする:動けない状態にして、メニューを出させる。ラウンドは始めない(天敵・餌・稲刈り機も動かない)
local function enterMenuWait(player: Player)
	local round = rounds[player]
	if not round then
		return
	end
	round.State = "Menu"
	round.Stage = 1
	round.Remaining = Config.RoundSeconds
	SetupService.SetCanReturnToMenu(player, false)
	FarmerPlayer.Reset(player) -- 巨人のときに変えたカメラのズーム距離を、元に戻す
	CrayfishService.SetAlive(player, false) -- 潜る・ジェットも受け付けない
	local humanoid = getHumanoid(player)
	if humanoid then
		humanoid.WalkSpeed = 0 -- 動けない
	end
	sendMenuState(player)
	ScoreService.SendBestScores(player)
end

-- メニューに戻す(フェーズも Menu にして、メニュー待ちにする)。
-- 「スタート」が通ったあとで、生まれ直しに失敗したときなど、メニューから抜けられなくなるのを防ぐ
local function returnToMenu(player: Player)
	SetupService.SetPhase(player, "Menu")
	enterMenuWait(player)
end

-- 選ばれた「やくわり」が、まだ遊べないとき(Config.Roles[role].Ready が false)、メニューに戻す。
-- メニューは出たまま(state = "Menu" を送り直す)
local function declineRole(player: Player)
	returnToMenu(player)
end

-- ザリガニのラウンドを始める(巨人のズーム距離が残っていれば戻してから、ふだんのラウンドを始める)
local function startCrayfishRound(player: Player)
	FarmerPlayer.Reset(player)
	startRound(player)
	fireRoundStart(player, "Crayfish")
end

-- 農家さんのラウンドを始める(仕様書 016)。ふだんのラウンドを始めて、キャラクターを巨人の農家さんにし、
-- AIザリガニを出してもらう(OnRoundStart の関数が呼ばれる)
local function startFarmerRound(player: Player, character: Model)
	startRound(player)
	FarmerPlayer.Apply(player, character)
	fireRoundStart(player, "Farmer")
end

-- 「やくわり」ごとの、ラウンドの始め方(キャラクターが生まれたあと、フェーズが Playing のときに呼ぶ)
local function startRoundForRole(player: Player, role: string, character: Model)
	if role == "Crayfish" then
		startCrayfishRound(player)
	elseif role == "Farmer" then
		startFarmerRound(player, character)
	else
		declineRole(player) -- 知らない「やくわり」は、メニューに戻す
	end
end

local function onCharacterAdded(player: Player, character: Model)
	if player.Character ~= character then
		return -- 呼ばれる前に、別のキャラクターに変わった
	end
	local found = character:WaitForChild("Humanoid", Config.CharacterWaitSeconds)
	if player.Character ~= character then
		return -- 待っている間に、別のキャラクターに変わった(新しいキャラクターの onCharacterAdded が、あとを引き受ける)
	end
	if not found or not found:IsA("Humanoid") then
		WarnOnce.Warn("RoundNoHumanoid", "[RoundService] Humanoid が見つからないので、ラウンドを始めません(メニューに戻します)")
		returnToMenu(player) -- 「スタート」のあとなら、メニューから抜けられなくなるのを防ぐ
		return
	end
	local humanoid = found :: Humanoid
	-- フェーズを読む直前にも、もう一度、いまのキャラクターか確かめる(ここから先は、待ちが入らないが、念のため)
	if player.Character ~= character then
		return
	end
	if SetupService.GetPhase(player) == "Playing" then
		startRoundForRole(player, SetupService.GetRole(player), character)
	else
		enterMenuWait(player) -- メニューにいる間は、ラウンドを始めない
	end
	humanoid.Died:Connect(function()
		notifyCaught(player) -- Playing でなければ、何もしない
	end)
end

-- 稲の見た目を更新する。RiceGrowthUpdateSeconds ごと、または段階が変わったときだけ(重いので毎回はしない)
local function updateRice(round: PlayerRound, elapsed: number)
	local now = os.clock()
	if now - lastRiceUpdateAt < Config.RiceGrowthUpdateSeconds and round.Stage == lastRiceStage then
		return
	end
	lastRiceUpdateAt = now
	lastRiceStage = round.Stage
	FieldService.SetGrowthProgress(math.clamp(elapsed / Config.RoundSeconds, 0, 1))
end

-- 保険の見張り:フェーズは Playing なのに、State が Menu のまま、Config.StartStuckSeconds 以上続いたら、メニューに戻す
-- (「スタート」のあとの生まれ直しが、どこかで止まったときに、メニューから抜けられなくなるのを防ぐ)。
-- メニューに戻したら true。ラウンドが始まったら(startRound)、時計はリセットされる
local function checkStartStuck(player: Player, round: PlayerRound): boolean
	if SetupService.GetPhase(player) ~= "Playing" then
		round.StuckSince = nil -- ふつうのメニュー待ち。見張らない
		return false
	end
	local now = os.clock()
	local since = round.StuckSince
	if since == nil then
		round.StuckSince = now -- 最初に見た時刻を覚える
		return false
	end
	if now - since < Config.StartStuckSeconds then
		return false
	end
	round.StuckSince = nil
	WarnOnce.Warn("RoundStartStuck", "[RoundService] 「スタート」のあと、ラウンドが始まらないので、メニューに戻します")
	returnToMenu(player)
	return true
end

-- 1秒ごとの更新:Playing 中の人の段階を計算し、クリア判定と通知をする
local function updateRounds()
	for player, round in rounds do
		if round.State == "Playing" then
			local elapsed = os.clock() - round.StartedAt
			if elapsed >= Config.RoundSeconds then
				-- 時間切れ:ザリガニは「稲刈りの日まで生き延びた」(クリア)。農家さんは「にげられた」(Caught)
				finishRound(player, round, if SetupService.GetRole(player) == "Farmer" then "Caught" else "Cleared")
			else
				round.Stage = calcStage(elapsed)
				round.Remaining = calcRemaining(elapsed)
				ScoreService.Tick(player, elapsed)
				sendState(player, round)
			end
			-- 稲の見た目は、いちばん新しく始めた人の進み具合に合わせる
			if player == latestPlayer and round.State == "Playing" then
				updateRice(round, elapsed)
			end
		elseif round.State == "Menu" then
			if not checkStartStuck(player, round) then
				-- メニュー待ちの人には、毎秒、知らせ直す(クライアントが起動する前に送った知らせを、取りこぼさないため)
				sendMenuState(player)
				ScoreService.SendBestScores(player)
			end
		end
	end
end

-- 生まれ直させる。キャラクター生成の処理(onCharacterAdded)で、フェーズに合わせて、ラウンドかメニュー待ちが始まる
local function reloadCharacter(player: Player)
	task.spawn(function()
		local ok, err = pcall(function()
			player:LoadCharacter()
		end)
		if not ok then
			WarnOnce.Warn("RoundReloadFailed", `[RoundService] LoadCharacter に失敗しました(メニューに戻します): {err}`)
			returnToMenu(player) -- 生まれ直せないと、ラウンドが始まらないので、メニューから抜けられなくなるのを防ぐ
		end
	end)
end

-- 稲・餌・天敵を最初の状態に戻す(「もう一度」・スタート・メニューへ戻る、で使う)
local function resetWorld()
	FieldService.ResetRice() -- 稲を最初に戻す(刈り株も元に戻る)
	lastRiceUpdateAt = os.clock()
	lastRiceStage = 1
	for _, callback in restartCallbacks do -- 天敵などを最初に戻す
		task.spawn(callback)
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
	if round.State ~= "Caught" and round.State ~= "Cleared" then -- (c) Caught か Cleared のときだけ(メニュー待ち・遊んでいる最中は受け付けない)
		return
	end
	local now = os.clock()
	if now - round.LastRestartAt < Config.RestartRequestMinInterval then -- (d) 連打
		return
	end
	round.LastRestartAt = now
	SetupService.SetCanReturnToMenu(player, false) -- やり直している間は、「メニューへ」を受け付けない

	resetWorld()
	reloadCharacter(player) -- 生まれ直す。onCharacterAdded で、新しいラウンドが始まる(同じ設定)
end

-- 「スタート」が受け付けられたときの中身(onStartAccepted が、エラーを受け止めながら呼ぶ)
local function beginStart(player: Player)
	local round = rounds[player]
	if not round then
		return
	end
	local role = SetupService.GetRole(player)
	local info = Config.Roles[role]
	if info == nil or not info.Ready then
		declineRole(player) -- まだ遊べない「やくわり」:メニューのまま
		return
	end
	resetWorld() -- 天敵・餌を最初の状態にし直す(農家さんAIの猶予は、ラウンドが始まったときに、やり直される)
	reloadCharacter(player) -- 生まれ直す。onCharacterAdded で、ラウンドが始まる
end

-- 「スタート」が受け付けられた(SetupService から呼ばれる。フェーズはすでに Playing)。
-- エラーが出たら、メニューに戻す(メニューから抜けられなくなるのを防ぐ)
local function onStartAccepted(player: Player)
	local ok, err = pcall(beginStart, player)
	if not ok then
		WarnOnce.Warn("RoundStartError", `[RoundService] 「スタート」の処理でエラーが出ました(メニューに戻します): {err}`)
		returnToMenu(player)
	end
end

-- 「メニューへ」が受け付けられた(SetupService から呼ばれる。フェーズはすでに Menu)
local function onMenuAccepted(player: Player)
	local round = rounds[player]
	if not round then
		return
	end
	round.State = "Menu" -- すぐに、遊んでいない扱いにする
	FarmerPlayer.Reset(player) -- 巨人のカメラのズーム距離を元に戻す(巨人のキャラクターは、生まれ直して消える)
	resetWorld()
	sendMenuState(player)
	reloadCharacter(player) -- 生まれ直す。onCharacterAdded で、動けない状態のメニュー待ちになる
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

	-- メニューの「スタート」「メニューへ」(仕様書 015)。お願いの確認は SetupService が行う
	SetupService.OnStart(onStartAccepted)
	SetupService.OnMenu(onMenuAccepted)

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

-- やり直しのときに呼ぶ関数を登録する(天敵を最初に戻すため)。
-- 「もう一度」だけでなく、「スタート」とメニューに戻るときも、呼ばれる(世界を最初の状態に戻す)
function RoundService.OnRestart(callback: () -> ())
	table.insert(restartCallbacks, callback)
end

-- ラウンドが始まったときに呼ぶ関数を登録する(仕様書 016。AIザリガニを出すため)。
-- 関数には、(プレイヤー, やくわり "Crayfish" か "Farmer")が渡される。ラウンドの開始(状態が Playing になった)直後に、別のスレッドで呼ばれる
function RoundService.OnRoundStart(callback: (Player, string) -> ())
	table.insert(roundStartCallbacks, callback)
end

-- ラウンドが終わったとき(つかまった・クリア・時間切れ)に呼ぶ関数を登録する(仕様書 016。AIザリガニを消すため)。
-- 関数には、(プレイヤー, やくわり, 終わり方 "Caught" か "Cleared")が渡される。別のスレッドで呼ばれる
function RoundService.OnRoundEnd(callback: (Player, string, string) -> ())
	table.insert(roundEndCallbacks, callback)
end

return RoundService
