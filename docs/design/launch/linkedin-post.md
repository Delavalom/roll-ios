# Roll launch post, rewritten (LinkedIn)

Replaces the Kleo draft. Paste this, attach `docs/design/ask-roll/video/ask-roll-demo.mp4` (the 51 s storyboard video with voiceover), put the links in the first comment, and reply to comments in the first hour.

---

I have 29,682 photos and videos on my iPhone 13 Pro Max. Today I typed "handwritten note" into them and got the right photo back in 24 milliseconds. Nothing left the phone to do that.

The idea isn't mine. Abdur Rahim released DigUp (digup.arahim.dev), a Mac app that runs Google DeepMind's EmbeddingGemma 2 over your files, and it took off on r/LocalLLaMA. I wanted it in my pocket. So I spent a week getting Gemma running on the iPhone itself, and building Roll, an app that uses it: describe a pile of photos in plain words, it finds the pile, you swipe to clean it. The model is a one-time 343 MB download. After that every photo and video becomes a vector that stays on the device. Search works in airplane mode.

Some numbers, measured on my own library. It's a Debug build, so the TestFlight and App Store ones should come in faster.

A photo embeds in 64 ms. A query embeds in 6.7 ms.
A typed search across all ~29,700 photos comes back in 24 to 29 ms warm, the query embedding included. The preset piles are 8 to 15 ms.
Indexing all 29,685 photos and videos took 75.8 minutes, 0 failures. About two thirds of that was the phone pausing because it got hot, so an unpacked run is closer to 27 minutes.
Warm search holds about 630 MB of memory. On a 2021 phone.

The first version of search took about 300 ms per query. Splitting the steps apart showed one full scored sort per prompt, so I replaced it with a single vDSP matrix multiply, kept the candidate rows in memory and aligned the scores as integers. 14.5 ms.

Two things were genuinely hard. Core ML first loads the model as one ~1 GB blob, more memory than iOS gives a single on-device model, so it's now 9 functions compiled one at a time. And iOS deletes the compiled model when the phone has under about 2 GB free, which on a nearly full phone means compiling for 20 minutes, watching the cache vanish, and doing it again.

I don't trust numbers without a check, so every step of the conversion is gated against Google's original model across 8 stages, and the build fails if the vectors drift.

Credit where it's due: almost none of this code is hand-written. It's 16 Claude Code sessions since Oct 22, 102 subagents, about 55 hours of agent time.

Roll itself is source-available, not open source: the app code is published under PolyForm Noncommercial, so you can read it, build it and use it for yourself, but not sell it. The model conversion and the Swift package are Apache 2.0, so anyone can run EmbeddingGemma 2 on Apple hardware.

What would you search your own camera roll for?

Links in the first comment.
