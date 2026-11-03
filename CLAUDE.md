# CLAUDE.md(このリポジトリの共通ルール)

このリポジトリは、ロブロックス(Roblox)のゲームを作るためのものです。
開発者は初心者です。専門用語は、初めて出すときに説明してください。返答は日本語で書いてください。

## ゲームの概要
- ゲーム名: **ZARIGANI**(開発者が決定。2026-11-03)
- コンセプト(一行): **日本の田んぼで、プレイヤーがザリガニになって逃げて生き延びる**(開発者が決定。細部は docs/game-concept.md の「案」であり、開発者が確認するまで確定扱いにしない)
- 対象: ロブロックスのプレイヤー(大半が子ども)
- 開発の進め方: 初心者が、Claude Codeと一緒に小さく作って、反応を見ながら育てる

## フォルダの地図
```
default.project.json   Rojo(同期ツール)の設定。Studioとコードをつなぐ
src/
  ReplicatedStorage/Shared/       サーバーとクライアントの両方が使う部品(設定値など)
  ServerScriptService/            サーバー側のスクリプト(判定・保存・課金)
    Services/                     機能ごとのまとまり(例:ザリガニ、田んぼ、ラウンド、天敵)
      Enemy/                      天敵の部品(行動、数字の補正、種類ごとの定義。足し方は docs/design/enemy-architecture.md)
  ServerStorage/Modules/          サーバー専用の部品
  StarterPlayer/StarterPlayerScripts/   クライアント側のスクリプト(画面・操作)
    Controllers/                  画面ごとの操作のまとまり
  StarterGui/                     画面(UI)に関するスクリプト
assets/
  images/           画像の元ファイル(アイコン、サムネ、UI)
  audio/            音の元ファイル
  CREDITS.md        素材の台帳(出どころと使用条件を必ず記録する)
docs/
  game-concept.md   ゲームの企画書(まずここを埋める)
  specs/            機能ごとの仕様書(_template.md を複製して使う)
  decisions/        決めたことの記録(なぜそうしたか)
  design/           設計の説明(拡張のしかたなど。初心者向け)
  playtest/         遊んでみた記録(誰が、どこで迷ったか、継続率など)
  marketing/        公開と宣伝の計画
    video-scripts/  縦動画の台本
.claude/agents/     役割ごとのClaude(scripter / reviewer)
```

## ファイル名の規則(Rojo)
- `名前.server.luau` → サーバー用のScript
- `名前.client.luau` → クライアント用のScript
- `名前.local.luau` → LocalScript
- `名前.luau` → ModuleScript(共通の部品)

## コードのルール
1. 所持金・アイテム・購入・スコアの判定は、必ずサーバー側で行う。クライアントから届く値は信用しない。
2. RemoteEventで受け取った値は、サーバー側で送信者・型・範囲・回数を検証する。
3. DataStore(データ保存)は pcall で包み、失敗時の再試行と、退出時の保存を入れる。
4. 設定値(価格・時間・確率)は `src/ReplicatedStorage/Shared/Config.luau` にまとめ、コードに直書きしない。
5. チャットがなくても遊べる設計にする(年齢確認でチャットが使えないプレイヤーがいる)。
6. 外部の画像・音・モデルのIDは、勝手に使わない。使うときは開発者に確認する。
7. 仕様書(docs/specs/)にない機能は、足さない。
8. 最初は一人用だが、将来は複数人で遊べるようにする。プレイヤーごとの状態(生存、潜っている、スタミナなど)は、1つの変数にせず、`Player` をキーにした表で持つ。

## 役割分担
- **司令塔**(普段のClaude Code): 依頼を分け、各担当に回し、結果をまとめる。
- **scripter**: 仕様書に従ってLuauを実装する。
- **reviewer**: 読み取り専用で、コードを確認して指摘する(直接は直さない)。
- **開発者(人間)**: ゲームの内容の決定、Studioでの見た目の調整、遊んでの最終確認。

## 作業の流れ(1機能ずつ)
1. docs/specs/ に仕様書を書く(`_template.md` を複製する)。
2. scripter が実装する。
3. reviewer が確認し、「重大」「要修正」「提案」で報告する。
4. 「重大」と「要修正」を直す。
5. 開発者が、Studioで遊んで確かめる。
6. 機能ごとのブランチで作業し、問題なければ main に取り込む。

## まだ決まっていないこと(勝手に決めないこと)
- 1回の長さ、課金の内容(企画書の案を、開発者が確認するまで)
- 収益化の方法(ゲームパスなど)
- 音の素材のID(開発者が選んで、Config の SoundIds に入れる。docs/design/sound.md)
