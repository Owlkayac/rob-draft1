--!strict
-- サーバー側の起動スクリプト。
-- 所持金・購入・スコアなどの判定は、必ずサーバー側で行う。

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)

print(`[{Config.GameName}] サーバー起動`)

local CrayfishService = require(script.Parent.Services.CrayfishService)

CrayfishService.Start()
