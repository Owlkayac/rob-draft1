--!strict
-- サーバー側の起動スクリプト。
-- 所持金・購入・スコアなどの判定は、必ずサーバー側で行う。

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)

print(`[{Config.GameName}] サーバー起動`)

local CrayfishService = require(script.Parent.Services.CrayfishService)

CrayfishService.Start()

local FieldService = require(script.Parent.Services.FieldService)
local RoundService = require(script.Parent.Services.RoundService)
local EnemyService = require(script.Parent.Services.EnemyService)

FieldService.Build() -- 田んぼ(ゆか・あぜ・稲・スタート地点)を作る
RoundService.Start() -- ラウンドの進行を始める
EnemyService.Start() -- 天敵「農家さん」を出して、見回りを始める
