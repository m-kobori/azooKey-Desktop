# Kiwi 開発環境セットアップ手順 (NT-830)

Kiwi は azooKey-Desktop をフォークした macOS 向け日本語 IME。
本ドキュメントは、フォーク〜ビルド〜インストールまでの実手順を記録する。

## 0. 前提環境

| 項目 | 要件 |
|---|---|
| OS | macOS 15 以降 |
| Xcode | **26.1 以降**（26.0 はビルド不可の可能性あり。16 系または 26.1+ を使う） |
| Homebrew | 導入済み |
| Apple ID | Personal Team での署名が可能なこと（Developer Program 未加入でも可） |

> Command Line Tools だけでは `xcodebuild` / アーカイブビルドができない。必ず **フル Xcode** を入れる（`xcode-select -p` が `/Applications/Xcode.app/...` を指すこと）。
>
> ```bash
> sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
> ```

## 1. 必要ツールのインストール

```bash
brew install git-lfs swiftlint
git lfs install
```

## 2. GitHub でフォーク

`azooKey/azooKey-Desktop` を自分のアカウントにフォークする。

```bash
# gh CLI を使う場合
gh repo fork azooKey/azooKey-Desktop --clone=false
```

本プロジェクトのフォーク: <https://github.com/m-kobori/azooKey-Desktop>

## 3. clone（`--recursive` 必須）

submodule に Zenzai の gguf 重みと言語モデル（`.marisa`）が含まれるため、
`--recursive` と Git LFS が必須。

```bash
git lfs install                                                   # 未実行の場合のみ
git clone --recursive https://github.com/m-kobori/azooKey-Desktop.git
cd azooKey-Desktop
```

### submodule 構成（このフォーク時点）

Notion のプロジェクトページには `zenz-v3.1-small-gguf` とあるが、**実際の submodule パスは異なる**。

| submodule | 内容 | 実体サイズ目安 |
|---|---|---|
| `azooKeyMac/Resources/gguf` | Zenzai の gguf 重み (`ggml-model-Q5_K_M.gguf`) | 約 70MB |
| `azooKeyMac/Resources/base_n5_lm` | 言語モデル (`*.marisa`) | 合計約 45MB |

## 4. submodule / LFS の実体取得を確認

clone 後、gguf がポインタのまま（数百 B）の場合は LFS 実体を取得する。

```bash
# submodule を初期化（--recursive し忘れた場合）
git submodule update --init

# gguf の実体を取得
git -C azooKeyMac/Resources/gguf lfs pull
git -C azooKeyMac/Resources/base_n5_lm lfs pull
```

サイズで実体取得を確認（数十 MB あれば OK。数百 B ならポインタのまま）:

```bash
ls -lh azooKeyMac/Resources/gguf/ggml-model-Q5_K_M.gguf   # → 約 70M
ls -lh azooKeyMac/Resources/base_n5_lm/*.marisa
```

## 5. 署名設定（初回のみ）

`install.sh` はアーカイブビルドを行うため、Xcode 上で署名が通っている必要がある。

1. `azooKeyMac.xcodeproj` を Xcode で開く
2. `azooKeyMac` ターゲット → Signing & Capabilities → Team を自分の Personal Team に変更
3. バンドル ID（`dev.ensan.inputmethod.azooKeyMac` など）を、自身が所有するプレフィックスへ一括置換
   （例: `dev.<yourname>.inputmethod.azooKeyMac`）

### 5-b. Apple Developer 登録なしでローカル運用する（アドホック署名）※本家からの変更点

無料 Apple ID / 未サインイン環境では、本家 `install.sh` の自動署名が通らない。
本アプリは **App Sandbox + App Groups** を含むため、`CODE_SIGN_IDENTITY="-"` の単純なアドホック
指定でも「requires a provisioning profile」で失敗する（制限エンタイトルメントの権限付与にプロファイルが要るため）。

そこで **「署名なしでビルド → 全体を手動でアドホック署名（`codesign -s -`）」** する方式を採用した。
kernel は埋め込みエンタイトルメントに基づき Sandbox を適用し、App Group コンテナは両プロセスの
`application-groups` が一致していれば生成されるため、ローカル実行なら Apple 登録なしで動く（**配布は不可**）。

この手順を `Tools/local_adhoc_install.sh` に一括化した。

```bash
# ビルド〜アドホック署名〜インストールまで一括（sudo パスワードを求められる）
./Tools/local_adhoc_install.sh

# 既に build/archive.xcarchive がある場合は署名+インストールのみ
./Tools/local_adhoc_install.sh --skip-build
```

要点（スクリプト内で実施）:

- `xcodebuild ... archive CODE_SIGNING_ALLOWED=NO` で未署名アーカイブを作る。
- エンタイトルメントの `$(PRODUCT_BUNDLE_IDENTIFIER)` を実 ID へ展開してから署名する。
- **`--deep` は使わない**。`--deep --entitlements` はネストの `ConverterServer` にもアプリ側権限
  （app-sandbox / mach-register）を誤伝播させ XPC を壊す。フレームワーク → `ConverterServer`
  （`ConverterServer.entitlements` = app-groups のみ）→ アプリ本体（`azooKeyMac.entitlements`）の
  順に**個別**署名する。
- **`com.apple.security.cs.disable-library-validation` を「アプリ本体」と「ConverterServer」の
  両方のエンタイトルメントに追加**する。アドホック署名では全バイナリが Team ID 無しになり、
  hardened runtime による Library Validation が同梱 `llama.framework` を「別 Team」として拒否し、
  dyld が起動時に `Library not loaded ... different Team IDs` でクラッシュする。アプリ本体・
  ConverterServer は**どちらも** llama.framework を読むため両方に必要。特に ConverterServer は
  keepalive の常駐サービスなので、付け忘れると crash-loop（`launchctl print` の `runs` が増え続け、
  `last exit reason = OS_REASON_DYLD`）に陥り **Mac 全体が重くなる**。ローカル専用ビルドのため
  検証を無効化して回避する（配布ビルドでは正規署名で全フレームワークが同一 Team になるため不要）。
- **App Sandbox と App Group を外す**（`com.apple.security.app-sandbox` と
  `com.apple.security.application-groups` を app / ConverterServer 両方から削除）。アドホック署名では
  Team ID が無く、macOS が App Group コンテナ（`~/Library/Group Containers/…`）を「自分の所有物」と
  認識できないため、そこへアクセスする度に「ほかのアプリのデータへのアクセス権」
  (`kTCCServiceSystemPolicyAppData`) プロンプトが出る（azooKey は学習・設定・履歴 DB を App Group に置き、
  特に**設定画面は起動時に全 Config 値を App Group の `UserDefaults` から読むため必発**）。`~/Library/Group
  Containers/` は sandbox を外しても保護対象のままなので、**App Group entitlement 自体を外す**必要がある。
  外すと:
    - `AppGroup.containerURL()` が nil を返し、学習/履歴は `~/Library/Application Support/azooKey/`、
      `Config` の `UserDefaults(suiteName: group…)` は `~/Library/Preferences/group.dev.ensan….plist`
      に保存される（どちらも保護対象外）。履歴 DB のフォールバックは `SegmentsManager.makeHistoryManager()`
      に実装済み（`.../azooKey/KiwiHistory/history.sqlite`）。
    - アプリ⇔ConverterServer は同一ユーザーで同じフォールバック先を使うため設定共有は維持される。
  この構成では azooKey が保護対象パスに一切触れないためプロンプトは出ない。
  **配布用の正規署名ビルドでは sandbox / App Group を戻すこと**（正規 Team ID なら所有物と認識されプロンプトは出ない。IME は sandbox 必須ではない）。
- インストールは署名を保つため `cp` ではなく `ditto` を使う。

将来 Apple Developer に登録して配布する場合は、この方式ではなく手順 5（Team + バンドル ID 変更）に切り替える。

## 6. ビルド & インストール

```bash
# Apple Developer 登録済みで手順 5 を実施した場合
./install.sh

# 登録なしでローカル運用する場合（推奨・手順 5-b）
./Tools/local_adhoc_install.sh
```

`.pkg` と同等の状態になる。開発中は azooKey プロセスを kill すると最新版が反映される。

```bash
# 反映（プロセス再起動）
pkill -f azooKeyMac || true
```

## 7. 入力ソースに追加

1. macOS からログアウト → 再ログイン
2. システム設定 > キーボード > 入力ソース > 「編集」
3. 左下「+」> 「日本語」> `azooKey` を追加 > 完了
4. メニューバーの入力ソースアイコンから `azooKey` を選択

## 8. 動作確認

- テキストエディタで「きょう」→ スペースで変換 → 「今日」などが出て確定できれば OK

## トラブルシューティング

| 症状 | 原因 | 対処 |
|---|---|---|
| ビルドエラー（ファイルが無い） | submodule / LFS 未取得 | `git submodule update --init` と `git -C <path> lfs pull` |
| 署名エラー | Team 未設定 / バンドル ID 未変更 | 手順 5 を実施（Team 変更とバンドル ID 置換の両方が必要） |
| `Packages are not supported when using legacy build locations` | Xcode のビルドロケーション設定 | 参照: <https://qiita.com/glassmonkey/items/3e8203900b516878ff2c> |
| 入力ソースに出ない | プロセス未再起動 | ログアウト/再ログイン、または azooKey プロセスを kill |
| azooKey を選んでも独自メニュー（設定…等）が出ない／変換できない | アプリ本体が Library Validation で `llama.framework` 読込拒否（`different Team IDs` でクラッシュ） | 手順 5-b の `disable-library-validation` を付けて再署名（`./Tools/local_adhoc_install.sh --skip-build`）。診断: `"/Library/Input Methods/azooKeyMac.app/Contents/MacOS/azooKeyMac"` を直接実行し dyld エラーを確認 |
| Mac 全体が重い＋入力がローマ字のまま（変換されない） | ConverterServer が同じ dyld エラーで crash-loop（keepalive 常駐が再起動を繰り返す）。変換エンジン不通のためローマ字素通り | 応急: `launchctl bootout gui/$(id -u)/dev.ensan.inputmethod.azooKeyMac.ConverterServer` で停止。恒久: ConverterServer 側にも `disable-library-validation` を付けて再署名・再インストール。確認: `launchctl print gui/$(id -u)/dev.ensan.inputmethod.azooKeyMac.ConverterServer` の `runs` と `last exit reason` |
| 「ほかのアプリのデータへのアクセス権」プロンプトが毎回出る（特に設定を開くと出る） | アドホック署名（Team ID 無し）で App Group コンテナ（`~/Library/Group Containers/`）を自分の所有物と認識できず、コンテナアクセスの度に App Data 保護が発動。sandbox を外すだけでは不十分 | 手順 5-b で App Sandbox **と App Group** を外して再ビルド・再署名・再インストール（`./Tools/local_adhoc_install.sh`）。学習/履歴/設定は保護対象外パスへフォールバックし共有も維持 |
| 変換精度が悪い | モデル重みがポインタのまま | 手順 4 で gguf のサイズを確認し `lfs pull` |
| `xcodebuild requires Xcode` | Command Line Tools のみ | フル Xcode を入れ `xcode-select -s` で切替 |

## 参考リンク

- azooKey-Desktop: <https://github.com/azooKey/azooKey-Desktop>
- Zenzai 技術詳細: <https://zenn.dev/azookey/articles/ea15bacf81521e>
- Kiwi プロジェクト（Notion）: <https://app.notion.com/p/f54195d544314239bda9922217f37a52>
