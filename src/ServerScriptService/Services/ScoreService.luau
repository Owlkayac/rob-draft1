--!strict
-- 点数とベスト記録をサーバーで管理する部品。仕様書 012 の 2・3・4。
-- 点数の計算と保存は、すべてサーバーが行う。クライアントには、表示用に ScoreState を送るだけ。
-- この部品は RoundService を読み込まない(循環を防ぐ。RoundService が、この部品を呼ぶ)。

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local WarnOnce = require(script.Parent.Enemy.WarnOnce)

-- プレイヤー1人ぶんの点数の状態
type PlayerScore = {
	Active: boolean, -- いまラウンド中か(終わったあとは、点が増えない)
	Eaten: number, -- 食べた餌の点
	Elapsed: number, -- 生き延びた秒数(Tick で教えてもらった値)
	Cleared: boolean, -- クリアしたか
	Score: number, -- いまの点数
	NewBest: boolean, -- このラウンドで、ベストを更新したか
	Best: number, -- ベスト記録
	BestLoaded: boolean, -- 保存してあるベストを読み込めたか
	LoadFailed: boolean, -- 読み込みに失敗したままか(その間は、保存しない)
	Dirty: boolean, -- 保存が必要か(ベストが、まだ保存されていない)
	Saving: boolean, -- いま保存している最中か(同じ人の保存が、二重に走らないため)
}

local ScoreService = {}

-- Player をキーにした表(将来、複数人でも動くように)
local states: { [Player]: PlayerScore } = {}
local scoreRemote: RemoteEvent? = nil
local store: DataStore? = nil
local pendingSaves = 0 -- いま保存している最中の数(サーバーが閉じるとき、待つため)

local function newState(): PlayerScore
	return {
		Active = false,
		Eaten = 0,
		Elapsed = 0,
		Cleared = false,
		Score = 0,
		NewBest = false,
		Best = 0,
		BestLoaded = false,
		LoadFailed = false,
		Dirty = false,
		Saving = false,
	}
end

-- 点数 = 食べた点 + 生き延びた秒数 × 1秒の点 + クリアのボーナス
local function calcScore(s: PlayerScore): number
	local score = s.Eaten + math.floor(s.Elapsed) * Config.ScorePerSecond
	if s.Cleared then
		score += Config.ClearBonus
	end
	return score
end

-- クライアントに、いまの点数を送る
local function sendState(player: Player, s: PlayerScore, eaten: boolean)
	local remote = scoreRemote
	if remote then
		remote:FireClient(player, s.Score, s.Best, s.NewBest, eaten)
	end
end

local function getKey(userId: number): string
	return "Player_" .. userId
end

-- 保存されていた値が、使える数字かを確かめる(使えなければ 0)
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

-- ベストを1回保存する(失敗したら、やり直す)。成功したら true。
-- 古い値と比べて、高いほうを残す(UpdateAsync)
local function saveOnce(userId: number, s: PlayerScore, dataStore: DataStore): boolean
	local value = s.Best
	local key = getKey(userId)
	pendingSaves += 1
	local saved = false
	for attempt = 0, Config.BestScoreRetries do
		if attempt > 0 then
			task.wait(Config.BestScoreRetryWaitSeconds)
		end
		local ok, err = pcall(function()
			dataStore:UpdateAsync(key, function(old: any): any
				if typeof(old) == "number" and old >= value then
					return nil -- すでに同じか高い記録がある。書き換えない
				end
				return value
			end)
		end)
		if ok then
			if s.Best == value then
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
	local storedBest = sanitizeStored(stored)
	s.BestLoaded = true
	if s.Best > storedBest then
		s.Dirty = true -- 読み込み中に、もっと高い点が出ていた
		task.spawn(saveBest, player.UserId, s)
	else
		-- 保存してあるベストのほうが高い(同じ)。読み込み前に「ベスト更新」になっていても、取り消す
		if s.NewBest then
			s.NewBest = false
		end
		s.Best = storedBest
		s.Dirty = false
	end
	sendState(player, s, false)
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

-- ラウンドの始まり:食べた点・経過・クリアを 0 に戻す。ベスト更新の印も戻す
function ScoreService.BeginRound(player: Player)
	local s = states[player]
	if not s then
		return
	end
	s.Active = true
	s.Eaten = 0
	s.Elapsed = 0
	s.Cleared = false
	s.NewBest = false
	s.Score = calcScore(s)
	sendState(player, s, false)
end

-- 餌を食べた:点を足して、すぐ知らせる。
-- 点が入ったら true、入らなかったら(プレイヤー不明・ラウンド外)false を返す
function ScoreService.AddFood(player: Player): boolean
	local s = states[player]
	if not s or not s.Active then
		return false
	end
	s.Eaten += Config.FoodPoints
	s.Score = calcScore(s)
	sendState(player, s, true)
	return true
end

-- 1秒ごと:経過秒から点数を計算し直して知らせる
function ScoreService.Tick(player: Player, elapsedSeconds: number)
	local s = states[player]
	if not s or not s.Active then
		return
	end
	s.Elapsed = math.max(0, elapsedSeconds)
	s.Score = calcScore(s)
	sendState(player, s, false)
end

-- ラウンドの終わり:最終の点数を決めて、ベストより高ければ更新して保存する
function ScoreService.EndRound(player: Player, cleared: boolean)
	local s = states[player]
	if not s or not s.Active then
		return
	end
	s.Active = false
	s.Cleared = cleared
	s.Score = calcScore(s)
	s.NewBest = s.Score > s.Best
	if s.NewBest then
		s.Best = s.Score
		s.Dirty = true
		task.spawn(saveBest, player.UserId, s)
	end
	sendState(player, s, false)
end

function ScoreService.GetScore(player: Player): number
	local s = states[player]
	if not s then
		return 0
	end
	return s.Score
end

return ScoreService
