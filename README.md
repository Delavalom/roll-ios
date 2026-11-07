# Roll

On-device AI photo cleanup for iPhone. Describe a pile of photos in plain words, Roll finds it with EmbeddingGemma running fully on the phone, and you swipe to clean. Nothing about a photo leaves the device.

See `AGENTS.md` for the repo map and commands, and `docs/superpowers/specs/2026-10-22-roll-design.md` for the design.

```
cp Team.xcconfig.example Team.xcconfig   # then fill in the team id
just gen && just build
just test
```

Requires Xcode, XcodeGen, `just`, and the sibling checkout `../embeddinggemma-coreml`.

## License

Roll is source-available, not open source. The code is published under the [PolyForm Noncommercial License 1.0.0](LICENSE.md).

- **Allowed:** personal, non-commercial use. You can read the code, learn from it, build it and install it on your own iPhone, and change it for yourself. Hobby projects, research, schools, charities and public bodies are covered too.
- **Not allowed:** any commercial use, such as selling this app or a modified copy, or using the code in a paid, subscription or ad-supported product.
- **Commercial rights** stay with the author. The official Roll app on the App Store is the only commercial release. To ask about a commercial license, email hi@delavalom.com.

The name "Roll", the app icon and the brand assets are not licensed for use in other apps.
