# Timer Desktop (Flutter macOS)

## 方針
- Flutter SDK は Docker コンテナ内にのみインストールします。
- ホスト macOS には Flutter/Dart をインストールしません。

## Docker 開発環境の起動
```bash
docker compose build
docker compose run --rm flutter bash
```

以降のコマンドは、すべてコンテナ内で実行します。

## ホストから直接実行する簡易ラッパー
```bash
./scripts/flutter.sh pub get
./scripts/flutter.sh analyze
./scripts/flutter.sh test
```

## push前チェック（推奨）
```bash
./scripts/prepush-check.sh
```

- `analyze` と `test` を連続実行し、成功時のみ push する運用にできます。

## コンテナ内での基本コマンド
```bash
flutter pub get
flutter analyze
flutter test
```

## 重要な制約（macOS デスクトップビルド）
- `flutter build macos` は Xcode と macOS ネイティブ環境が必須です。
- Linux ベースの Docker コンテナ内では macOS バイナリを生成できません。

## macOS バイナリの現実的な作り方
1. GitHub Actions の `macos-latest` ランナーでビルドする
2. もしくは、専用の macOS ビルド端末（ローカルとは分離）でビルドする

## 主要仕様
- Provider で状態管理
- flutter_tts で音声キュー再生
- shared_preferences で設定保存
- 1秒周期 (`Timer.periodic`) で状態更新

## GitHub Actions (macOS ビルド)
- workflow: `/Users/user/Developer/Timer/.github/workflows/macos-build.yml`
- 手動実行: Actions から `macOS Build` を `Run workflow`
- タグ実行: `v1.0.0` のような `v*` タグ push で自動実行
- 成果物: Actions Artifact に zip を保存
- タグ実行時: GitHub Release に zip を自動添付
- `.app` 名は固定せず自動検出するため、`Runner.app` 以外でもパッケージ化できます。

## Git も Docker 内で実行する
```bash
./scripts/git.sh status
./scripts/git.sh add .
./scripts/git.sh commit -m "message"
./scripts/git.sh push origin main
```

- `scripts/git.sh` は UID/GID をホストに合わせて実行するため、権限崩れを避けられます。
- `~/.ssh` があれば読み取り専用でコンテナに渡します（`known_hosts` は `.codex-git-home/.ssh/` に保存）。
- Git の `--global` 設定はプロジェクト内の `.codex-git-home/` に保存され、ホスト環境設定は汚れません。
- `docker compose` と `docker-compose` のどちらの環境でも動作するようにしています。
