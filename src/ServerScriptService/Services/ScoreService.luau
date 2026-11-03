--!strict
-- 点数とベスト記録をサーバーで管理する部品。仕様書 012 の 2・3・4、仕様書 015。
-- 点数の計算と保存は、すべてサーバーが行う。クライアントには、表示用に ScoreState と BestScores を送るだけ。
-- この部品は RoundService を読み込まない(循環を防ぐ。RoundService が、この部品を呼ぶ)。
-- 仕様書 015:
--   ・ベスト記録は「やくわり」×「なんいど」の組み合わせごとに、別々に持つ。
--     保存の形: 1人1つのキー("Player_" .. UserId)の値が、表 { ["Crayfish_Normal"] = 数字, ... }。
--     これまでの形(数字だけ)で保存されていた記録は、"Crayfish_Normal" として引きつぐ。
--   ・点数には、難易度の倍率(ScoreMultiplier)をかけて、整数に丸める。
--   ・いまの「やくわり」「なんいど」は SetupService から読む(SetupService は、この部品を読み込まない)。
-- 仕様書 016:点数は「やくわり」で式が分かれる。
--   ・Crayfish(ザリガニ): (餌などの点 + 生き延びた秒数 × ScorePerSecond + クリアのボーナス)× 難易度の倍率
--   ・Farmer(農家さん):  (つかまえた点 + クリアのとき(のこり秒 × PreyTimeBonusPerSecond + クリアのボーナス))× 難易度の倍率
--     つかまえた点などは AddPoints で足す。生き延びた秒数の点は、農家さんには入らない。

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local WarnOnce = require(script.Parent.Enemy.WarnOnce)
local SetupService = require(script.Parent.SetupService)

-- プレイヤー1人ぶんの点数の状態
type PlayerScore = {
	Active: boolean, -- いまラウンド中か(終わったあとは、点が増えない)
	Points: number, -- 足した点の合計(餌を食べた点・つかまえた点。AddPoints で足す)
	Elapsed: number, -- 生き延びた秒数(Tick で教えてもらった値)
	Cleared: boolean, -- クリアしたか
	Score: number, -- いまの点数
	NewBest: boolean, -- このラウンドで、ベストを更新したか
	Bests: { [string]: number }, -- ベスト記録の表(キーは「やくわり_なんいど」。例 "Crayfish_Normal")
	LastEndKey: string?, -- 最後にラウンドを終えたときのキー(読み込み後に「ベスト更新」を取り消すために使う)
	BestLoaded: boolean, -- 保存してあるベストを読み込めたか
	LoadFailed: boolean, -- 読み込みに失敗したままか(その間は、保存しない)
	Dirty: boolean, -- 保存が必要か(ベストが、まだ保存されていない)
	Saving: boolean, -- いま保存している最中か(同じ人の保存が、二重に走らないため)
}

local ScoreService = {}

-- Player をキーにした表(将来、複数人でも動くように)
local states: { [Player]: PlayerScore } = {}
local scoreRemote: RemoteEvent? = nil
local bestScoresRemote: RemoteEvent? = nil
local store: DataStore? = nil
local pendingSaves = 0 -- いま保存している最中の数(サーバーが閉じるとき、待つため)

-- これまでの形(数字だけ)の記録を、引きつぐ先のキー(仕様書 015)
local LEGACY_KEY = "Crayfish_Normal"

local function newState(): PlayerScore
	return {
		Active = false,
		Points = 0,
		Elapsed = 0,
		Cleared = false,
		Score = 0,
		NewBest = false,
		Bests = {},
		LastEndKey = nil,
		BestLoaded = false,
		LoadFailed = false,
		Dirty = false,
		Saving = false,
	}
end

-- いまの「やくわり_なんいど」のキー(例: "Crayfish_Normal")
local function comboKey(player: Player): string
	return SetupService.GetRole(player) .. "_" .. SetupService.GetDifficulty(player)
end

-- 難易度の点数の倍率。使えない値(数字でない・0以下・NaN・無限大)のときは 1 倍
local function getMultiplier(player: Player): number
	local value = SetupService.GetDifficultyParams(player).ScoreMultiplier
	if type(value) ~= "number" or value ~= value or value <= 0 or value == math.huge then
		return 1
	end
	return value
end

-- ザリガニの点数:足した点 + 生き延びた秒数 × 1秒の点 + クリアのボーナス
local function calcCrayfishScore(s: PlayerScore): number
	local score = s.Points + math.floor(s.Elapsed) * Config.ScorePerSecond
	if s.Cleared then
		score += Config.ClearBonus
	end
	return score
end

-- 農家さんの点数:つかまえた点 +(クリアのとき)のこり秒 × 1秒の点 + クリアのボーナス。生き延びた秒数の点は入らない
local function calcFarmerScore(s: PlayerScore): number
	local score = s.Points
	if s.Cleared then
		local remainingSeconds = math.floor(math.max(0, Config.RoundSeconds - s.Elapsed))
		score += remainingSeconds * Config.PreyTimeBonusPerSecond + Config.ClearBonus
	end
	return score
end

-- 点数 = 「やくわり」ごとの式 × 難易度の倍率(整数に丸める)
local function calcScore(player: Player, s: PlayerScore): number
	local score = if SetupService.GetRole(player) == "Farmer" then calcFarmerScore(s) else calcCrayfishScore(s)
	return math.floor(score * getMultiplier(player) + 0.5)
end

-- クライアントに、いまの点数を送る。ベストは、いまの「やくわり」×「なんいど」の組み合わせのもの
local function sendState(player: Player, s: PlayerScore, eaten: boolean)
	local remote = scoreRemote
	if remote then
		local best = s.Bests[comboKey(player)] or 0
		remote:FireClient(player, s.Score, best, s.NewBest, eaten)
	end
end

-- メニュー用に、ベスト記録の表を送る
local function sendBestScores(player: Player, s: PlayerScore)
	local remote = bestScoresRemote
	if remote then
		remote:FireClient(player, s.Bests)
	end
end

local function getKey(userId: number): string
	return "Player_" .. userId
end

-- 保存されていた数字が、使える数字かを確かめる(使えなければ 0)
local function sanitizeStored(value: unknown): number
	if typeof(value) ~= "number" then
		return 0
	end
	local number = value :: number
	if number ~= number or number < 0 or number == math.huge then
		return 0 -- NaN、マイナス、無限大は使わない
	end
	return math.floor(number)
end

-- 保存されていた値を、ベスト記録の表にする。
--   数字(これまでの形)なら { Crayfish_Normal = 数字 }、表なら、使える数字だけ写す。それ以外は空の表
local function parseStored(value: unknown): { [string]: number }
	local result: { [string]: number } = {}
	if typeof(value) == "number" then
		local number = sanitizeStored(value)
		if number > 0 then
			result[LEGACY_KEY] = number
		end
	elseif typeof(value) == "table" then
		local entries = value :: any
		for key, entry in entries do
			if type(key) == "string" then
				local number = sanitizeStored(entry)
				if number > 0 then
					result[key] = number
				end
			end
		end
	end
	return result
end

-- 保存してある値(old)と、自分のベスト(mine)を、キーごとに高いほうを残してまとめる。
-- 書き換える必要がなければ nil(UpdateAsync では「書き換えない」の意味)
local function mergeStored(old: unknown, mine: { [string]: number }): { [string]: number }?
	local merged = parseStored(old)
	local changed = typeof(old) ~= "table" -- 数字(これまでの形)や空からは、表に変える
	for key, value in mine do
		if value > (merged[key] or 0) then
			merged[key] = value
			changed = true
		end
	end
	if not changed then
		return nil
	end
	return merged
end

-- 表を複製する(保存を始めた時点の値を覚えておくため)
local function copyBests(source: { [string]: number }): { [string]: number }
	local copy: { [string]: number } = {}
	for key, value in source do
		copy[key] = value
	end
	return copy
end

-- 2つの表が同じ中身か
local function sameBests(a: { [string]: number }, b: { [string]: number }): boolean
	for key, value in a do
		if b[key] ~= value then
			return false
		end
	end
	for key, value in b do
		if a[key] ~= value then
			return false
		end
	end
	return true
end

-- ベストを1回保存する(失敗したら、やり直す)。成功したら true。
-- 古い値と比べて、キーごとに高いほうを残す(UpdateAsync)
local function saveOnce(userId: number, s: PlayerScore, dataStore: DataStore): boolean
	local snapshot = copyBests(s.Bests) -- 保存を始めた時点の値
	local key = getKey(userId)
	pendingSaves += 1
	local saved = false
	for attempt = 0, Config.BestScoreRetries do
		if attempt > 0 then
			task.wait(Config.BestScoreRetryWaitSeconds)
		end
		local ok, err = pcall(function()
			dataStore:UpdateAsync(key, function(old: any): any
				return mergeStored(old, snapshot) -- すでに同じか高い記録ばかりなら nil(書き換えない)
			end)
		end)
		if ok then
			if sameBests(s.Bests, snapshot) then
				s.Dirty = false
			end
			saved = true
			break
		elseif attempt == Config.BestScoreRetries then
			WarnOnce.Warn(
				"ScoreSave",
				`[ScoreService] ベスト記録を保存できませんでした(公開前の Studio では起こります): {err}`
			)
		end
	end
	pendingSaves -= 1
	return saved
end

-- ベストを保存する。読み込みに成功していない人は、保存しない(もとの記録を上書きしないため)。
-- すでに保存中なら、何もせず戻る。保存中にベストがまた変わっていたら(Dirty のまま)、終わったあとにもう一度保存する
local function saveBest(userId: number, s: PlayerScore)
	local dataStore = store
	if dataStore == nil or not s.BestLoaded or not s.Dirty or s.Saving then
		return
	end
	s.Saving = true
	while s.Dirty do
		if not saveOnce(userId, s, dataStore) then
			break -- 失敗した。無限にくり返さない(Dirty のままなので、次の機会に保存する)
		end
	end
	s.Saving = false
end

-- 読み込んだ表を、いまのベストにまとめる(キーごとに高いほう)。保存が必要なら true
local function mergeLoaded(s: PlayerScore, storedBests: { [string]: number }): boolean
	local needSave = false -- 読み込み中に、保存してあるより高い点が出ていたか
	for key, storedValue in storedBests do
		local mine = s.Bests[key] or 0
		if mine > storedValue then
			needSave = true
		else
			-- 保存してあるベストのほうが高い(同じ)。読み込み前に「ベスト更新」になっていても、取り消す
			s.Bests[key] = storedValue
			if s.NewBest and s.LastEndKey == key then
				s.NewBest = false
			end
		end
	end
	for key, mine in s.Bests do
		if storedBests[key] == nil and mine > 0 then
			needSave = true -- 保存してある表に、まだないキー
		end
	end
	return needSave
end

-- 保存してあるベストを読み込む。失敗したら、やり直す。それでもだめなら、そのプレイ中だけのメモリで続ける
local function loadBest(player: Player, s: PlayerScore)
	local dataStore = store
	if dataStore == nil then
		s.LoadFailed = true
		return
	end
	local key = getKey(player.UserId)
	local loaded = false
	local stored: unknown = nil
	local lastError: unknown = nil
	for attempt = 0, Config.BestScoreRetries do
		if attempt > 0 then
			task.wait(Config.BestScoreRetryWaitSeconds)
		end
		if states[player] ~= s then
			return -- 待っている間に退出した
		end
		local ok, result = pcall(function(): any
			return (dataStore:GetAsync(key))
		end)
		if ok then
			loaded = true
			stored = result
			break
		end
		lastError = result
	end
	if not loaded then
		s.LoadFailed = true
		WarnOnce.Warn(
			"ScoreLoad",
			`[ScoreService] ベスト記録を読み込めませんでした。このプレイ中だけの記録になります(公開前の Studio では起こります): {lastError}`
		)
		return
	end
	if states[player] ~= s then
		return -- 読み込み中に退出した。何も送らない
	end
	s.BestLoaded = true
	local needSave = mergeLoaded(s, parseStored(stored))
	s.Dirty = needSave
	if needSave then
		task.spawn(saveBest, player.UserId, s)
	end
	sendState(player, s, false)
	sendBestScores(player, s)
end

local function onPlayerAdded(player: Player)
	if states[player] then
		return
	end
	local s = newState()
	states[player] = s
	task.spawn(loadBest, player, s)
end

local function onPlayerRemoving(player: Player)
	local s = states[player]
	states[player] = nil
	if s then
		task.spawn(saveBest, player.UserId, s) -- 変わっていれば保存(変わっていなければ何もしない)
	end
end

-- サーバーが閉じるとき、全員ぶんの、変わっているものを保存する。待つのは、最長で Config.BestScoreCloseWaitSeconds
local function onClose()
	for player, s in states do
		task.spawn(saveBest, player.UserId, s)
	end
	local deadline = os.clock() + Config.BestScoreCloseWaitSeconds
	while pendingSaves > 0 and os.clock() < deadline do
		task.wait(Config.BestScoreCloseWaitStepSeconds)
	end
end

function ScoreService.Start()
	local remote = Instance.new("RemoteEvent")
	remote.Name = Config.ScoreStateRemoteName
	remote.Parent = ReplicatedStorage
	scoreRemote = remote

	local bestRemote = Instance.new("RemoteEvent")
	bestRemote.Name = Config.BestScoresRemoteName
	bestRemote.Parent = ReplicatedStorage
	bestScoresRemote = bestRemote

	-- 公開前の Studio などでは失敗することがある。止まらずに、メモリだけで続ける
	local ok, result = pcall(function(): DataStore
		return DataStoreService:GetDataStore(Config.BestScoreStoreName)
	end)
	if ok then
		store = result
	else
		WarnOnce.Warn("ScoreStore", `[ScoreService] DataStore を使えません。ベスト記録は保存されません: {result}`)
	end

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
	game:BindToClose(onClose)
end

-- ラウンドの始まり:足した点・経過・クリアを 0 に戻す。ベスト更新の印も戻す
function ScoreService.BeginRound(player: Player)
	local s = states[player]
	if not s then
		return
	end
	s.Active = true
	s.Points = 0
	s.Elapsed = 0
	s.Cleared = false
	s.NewBest = false
	s.Score = calcScore(player, s)
	sendState(player, s, false)
end

-- 点を足して、すぐ知らせる(餌を食べた・ザリガニをつかまえた、の共通の処理)。
-- eaten は、クライアントへの「食べた」の印(食べた音を鳴らすため)。
-- 点が入ったら true、入らなかったら(プレイヤー不明・ラウンド外・使えない点)false を返す
local function addPoints(player: Player, points: number, eaten: boolean): boolean
	local s = states[player]
	if not s or not s.Active then
		return false
	end
	if type(points) ~= "number" or points ~= points or points <= 0 or points == math.huge then
		return false -- NaN・0以下・無限大は足さない
	end
	s.Points += points
	s.Score = calcScore(player, s)
	sendState(player, s, eaten)
	return true
end

-- 汎用の点を足す(仕様書 016:ザリガニをつかまえた点など)。入ったら true、入らなかったら false
function ScoreService.AddPoints(player: Player, points: number): boolean
	return addPoints(player, points, false)
end

-- 餌を食べた:餌の点を足して、すぐ知らせる。
-- 点が入ったら true、入らなかったら(プレイヤー不明・ラウンド外)false を返す
function ScoreService.AddFood(player: Player): boolean
	return addPoints(player, Config.FoodPoints, true)
end

-- 1秒ごと:経過秒から点数を計算し直して知らせる
function ScoreService.Tick(player: Player, elapsedSeconds: number)
	local s = states[player]
	if not s or not s.Active then
		return
	end
	s.Elapsed = math.max(0, elapsedSeconds)
	s.Score = calcScore(player, s)
	sendState(player, s, false)
end

-- ラウンドの終わり:最終の点数を決めて、その組み合わせのベストより高ければ更新して保存する
function ScoreService.EndRound(player: Player, cleared: boolean)
	local s = states[player]
	if not s or not s.Active then
		return
	end
	s.Active = false
	s.Cleared = cleared
	s.Score = calcScore(player, s)
	local key = comboKey(player)
	s.LastEndKey = key
	s.NewBest = s.Score > (s.Bests[key] or 0)
	if s.NewBest then
		s.Bests[key] = s.Score
		s.Dirty = true
		task.spawn(saveBest, player.UserId, s)
		sendBestScores(player, s)
	end
	sendState(player, s, false)
end

-- メニュー用に、ベスト記録の表を送り直す(クライアントが、まだ受け取れる状態でなかったときのため。RoundService が呼ぶ)
function ScoreService.SendBestScores(player: Player)
	local s = states[player]
	if not s then
		return
	end
	sendBestScores(player, s)
end

function ScoreService.GetScore(player: Player): number
	local s = states[player]
	if not s then
		return 0
	end
	return s.Score
end

return ScoreService
