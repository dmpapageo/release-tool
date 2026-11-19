# release_tool

A small Dart CLI for shipping a mobile app to the App Store and Google Play. It
knows nothing about any one app: everything app-specific lives in a
`release.yaml` in the app's repo.

## Commands

- `check-listing`: reads the fastlane metadata tree and reports every missing
  required field and every field over its store limit, for each enabled store
  and locale, in one run. Exits 1 on Listing problems.
- `bump`: sets the next build number (or a higher App version with
  `--version`), renames the Play changelog to the new build, commits and tags
  `v<version>+<build>`. Refuses a dirty tree.
- `status`: reads the App Store and Google Play state of the latest Release and
  writes it to a status file. Exits 0 when done, 3 while a Release is in
  flight, 1 on failure. `status --help` lists the exit codes.

Every command exits 64 on a bad command line or an unreadable config.

## Use it from an app

Add it as a git dev dependency in the app's `pubspec.yaml`, pinned to a tag:

```yaml
dev_dependencies:
  release_tool:
    git:
      url: https://github.com/dmpapageo/release-tool.git
      ref: v1.0.0
```

Then run it from the app's root:

```sh
dart run release_tool:release check-listing --config release.yaml
dart run release_tool:release bump --config release.yaml
dart run release_tool:release status --config release.yaml
```

## Config

`release.yaml`, with paths relative to its folder:

```yaml
bundle_id: com.example.app
android_package: com.example.app
app_store_app_id: "1234567890"   # optional until the app exists in App Store Connect
locales: [en-US]
stores: [apple, play]
# Names of the environment variables that hold each key file's path and the
# App Store Connect issuer id. The keys themselves never go in the repo.
keys:
  app_store_connect: ASC_KEY_PATH          # path to AuthKey_<KEYID>.p8
  app_store_connect_issuer: ASC_ISSUER_ID
  play_service_account: PLAY_KEY_PATH      # path to the service account JSON
hud_file: ~/metrics.csv   # optional: CSV that `status` keeps one row in
status_file: STATUS.md    # optional: where `status` writes its report
```

## Develop

```sh
dart pub get
dart test
```

CI runs `dart format`, `dart analyze --fatal-infos`, the tests with coverage
and a 70% line floor.

## License

MIT, see [LICENSE](LICENSE).
