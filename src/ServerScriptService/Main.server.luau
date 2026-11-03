--!strict
-- サーバー側の起動スクリプト。
-- 所持金・購入・スコアなどの判定は、必ずサーバー側で行う。

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)

print(`[{Config.GameName}] サーバー起動`)

-- メニューで選んだ内容(やくわり・なんいど)を持つ部品。CrayfishService・ScoreService・RoundService が読むので、いちばん先に始める
local SetupService = require(script.Parent.Services.SetupService)
SetupService.Start()

local CrayfishService = require(script.Parent.Services.CrayfishService)

CrayfishService.Start()

local FieldService = require(script.Parent.Services.FieldService)
local RoundService = require(script.Parent.Services.RoundService)
local EnemyService = require(script.Parent.Services.EnemyService)
local ScoreService = require(script.Parent.Services.ScoreService)
local FoodService = require(script.Parent.Services.FoodService)
local PreyService = require(script.Parent.Services.PreyService)

FieldService.Build() -- 田んぼ(ゆか・あぜ・稲・スタート地点)を作る
ScoreService.Start() -- 点数とベスト記録を始める(RoundService より先)
RoundService.Start() -- ラウンドの進行を始める
EnemyService.Start() -- 天敵「農家さん」を出して、見回りを始める
FoodService.Start() -- 餌を置いて、食べる判定を始める
PreyService.Start() -- AIのザリガニ(農家さんモードの相手)の準備を始める。ラウンドが始まったら、RoundService が知らせる(仕様書 016)
