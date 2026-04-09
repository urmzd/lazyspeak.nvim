# Changelog

## 0.4.1 (2026-04-09)

### Documentation

- add LICENSE and README to sub-crate for publishing compliance ([336eeff](https://github.com/urmzd/lazyspeak.nvim/commit/336eeff41f27064dd81c6bdd83420988534f6d75))
- **spec**: update architecture documentation ([93c4c56](https://github.com/urmzd/lazyspeak.nvim/commit/93c4c56fbd6f93b9b46aaf9f047ee7c594b99556))

### Refactoring

- **main**: update entry point after crate consolidation ([9a92630](https://github.com/urmzd/lazyspeak.nvim/commit/9a926307e97787fa9ca91387aed0531317805033))
- **lib**: move core library into main crate ([5313974](https://github.com/urmzd/lazyspeak.nvim/commit/531397450ca8f16770681a37d2a55563e82bc569))
- **workspace**: consolidate lazyspeak-core into main crate ([ca0f76d](https://github.com/urmzd/lazyspeak.nvim/commit/ca0f76d073e7c42adb6143f79f475e06c47c8477))

### Miscellaneous

- fix cargo fmt import formatting ([da70048](https://github.com/urmzd/lazyspeak.nvim/commit/da7004822fe3941e8e59177a9d6151fba6e02de7))
- **lazyspeak-core**: remove library module ([dd1bd13](https://github.com/urmzd/lazyspeak.nvim/commit/dd1bd13b5b988ed06050b76652685f3062d68a66))
- **release**: remove lazyspeak-core publishing step ([bcf406e](https://github.com/urmzd/lazyspeak.nvim/commit/bcf406e6d7a127f9576af0b4f93b4bf27df95fe4))

[Full Changelog](https://github.com/urmzd/lazyspeak.nvim/compare/v0.4.0...v0.4.1)


## 0.4.0 (2026-04-06)

### Features

- **pipeline**: create modular streamsafe pipeline architecture ([d637c18](https://github.com/urmzd/lazyspeak.nvim/commit/d637c185fbc772a06ba77f1639c1d120d0dac249))

### Refactoring

- **main**: migrate to async/tokio with pipeline pattern ([8831593](https://github.com/urmzd/lazyspeak.nvim/commit/8831593acb97f3eb9f91372a05f140b2ddc4a575))

### Miscellaneous

- **deps**: add streamsafe and tokio-util dependencies ([442cd96](https://github.com/urmzd/lazyspeak.nvim/commit/442cd96cd23b535fce4a199d8d595a60e4287a42))
- add linguist overrides to fix language stats ([3f2b0f3](https://github.com/urmzd/lazyspeak.nvim/commit/3f2b0f38c7f36f1e921b6fa3c27842ccf1bb758f))

[Full Changelog](https://github.com/urmzd/lazyspeak.nvim/compare/v0.3.0...v0.4.0)


## 0.3.0 (2026-04-05)

### Features

- add teasr demo config (#3) ([6563cf2](https://github.com/urmzd/lazyspeak.nvim/commit/6563cf227ebceba6e77d0bcd648cd8c0711ce4f7))

[Full Changelog](https://github.com/urmzd/lazyspeak.nvim/compare/v0.2.0...v0.3.0)


## 0.2.0 (2026-04-04)

### Features

- interactive push-to-talk UI, auto model download, and startup improvements (#2) ([073e9f8](https://github.com/urmzd/lazyspeak.nvim/commit/073e9f84922cc2aa6724fb23329e282221514d73))

[Full Changelog](https://github.com/urmzd/lazyspeak.nvim/compare/v0.1.2...v0.2.0)


## 0.1.2 (2026-04-03)

### Bug Fixes

- **ci**: install libasound2-dev for publish verification ([531329a](https://github.com/urmzd/lazyspeak.nvim/commit/531329a13ba1e423c2bbed8ed6d6cc4a070942b4))

[Full Changelog](https://github.com/urmzd/lazyspeak.nvim/compare/v0.1.1...v0.1.2)


## 0.1.1 (2026-04-02)

### Bug Fixes

- add version to lazyspeak-core workspace dependency ([4620c0b](https://github.com/urmzd/lazyspeak.nvim/commit/4620c0b7b991e19bbcca959f91f05edd4f8c86e6))

[Full Changelog](https://github.com/urmzd/lazyspeak.nvim/compare/v0.1.0...v0.1.1)


## 0.1.0 (2026-04-02)

### Features

- pluggable STT backends (HTTP + ONNX) via SpeechTranscriber trait ([b767ad0](https://github.com/urmzd/lazyspeak.nvim/commit/b767ad0b6a47464b0ebfa4f489f408343242e541))
- **core**: auto-launch llama-server on plugin start ([6c4e25c](https://github.com/urmzd/lazyspeak.nvim/commit/6c4e25cd2b17141d21d666bcef7a5d450a4529f3))
- **health**: validate llama-server installation ([15a0121](https://github.com/urmzd/lazyspeak.nvim/commit/15a01212726f5f8745408dba3f77de18ed5878ef))
- **install**: add llama-server process management ([09e1fc4](https://github.com/urmzd/lazyspeak.nvim/commit/09e1fc4f42b8d3f8bd7f6ff7724119b9802ec508))

### Documentation

- document llama-server auto-startup behavior ([078113f](https://github.com/urmzd/lazyspeak.nvim/commit/078113fb4ca657a0169f4c7dd453e6cc0068fdcd))

### Miscellaneous

- add sr release pipeline + refactor STT to llama-server (#1) ([53f5334](https://github.com/urmzd/lazyspeak.nvim/commit/53f5334c2b8de7225f2eb26e41db5b7205a65910))
