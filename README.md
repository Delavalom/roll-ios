# Roll

On-device AI photo cleanup for iPhone. Describe a pile of photos in plain words, Roll finds it with EmbeddingGemma running fully on the phone, and you swipe to clean. Nothing about a photo leaves the device.

See `AGENTS.md` for the repo map and commands, and `docs/superpowers/specs/2026-10-22-roll-design.md` for the design.

```
cp Team.xcconfig.example Team.xcconfig   # then fill in the team id
just gen && just build
just test
```

Requires Xcode, XcodeGen, `just`, and the sibling checkout `../embeddinggemma-coreml`.
