# rob-draft1

ロブロックス(Roblox)のゲーム開発用リポジトリです。
Claude Code(AIの開発チーム)と一緒に、小さく作って育てます。

## 必要なもの
- Roblox Studio(制作ツール、無料)
- Rojo(コードとStudioをつなぐ同期ツール): https://rojo.space/
- Claude Code

## はじめかた
1. このリポジトリをパソコンにクローンする。
2. ターミナルで `rojo serve` を実行する。
3. Roblox Studioを開き、Rojoのプラグインから「Connect」を押す。
4. `src/` の中のコードが、Studioに自動で反映される。
5. Claude Codeを開き、`/agents` で scripter と reviewer が表示されることを確認する。

## 次にやること
1. `docs/game-concept.md` を埋めて、ゲームのコンセプトを決める。
2. 最初の機能の仕様書を `docs/specs/` に書く。
3. scripter に実装を頼み、reviewer に確認してもらう。

詳しいルールは `CLAUDE.md` を見てください。
