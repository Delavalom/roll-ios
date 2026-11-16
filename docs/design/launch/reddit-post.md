# Roll launch post for Reddit (r/LocalLLaMA)

This mirrors the DigUp Reddit post (r/LocalLLaMA, author A-Rahim), which broke down as: one sentence naming the thing, five quoted example searches with the result, one paragraph of real numbers with the mechanism, license honestly stated, repo link, then "I'd really appreciate any feedback". Video attached, links allowed in the body on Reddit.

Post it BEFORE the LinkedIn recap, the way DigUp did it: Reddit first, then the LinkedIn post can say "it took off on r/LocalLLaMA".

## Title

Roll: EmbeddingGemma 2 on the iPhone's Neural Engine. Searching 29,682 photos offline in ~15 ms

## Body

DigUp showed what Google DeepMind's EmbeddingGemma 2 can do over a whole file library on a Mac. I wanted that on the phone, so I ported the model to Core ML, ran it on the Neural Engine, and built Roll, an iPhone app where you describe a pile of photos in plain words and swipe to clean it. Every photo and video becomes a vector on the device; the model is a one-time 343 MB download and search never touches the network.

What a search looks like:

* "handwritten note" finds the page
* "invoice" finds the receipts
* "chat screenshot" finds the conversation I half remember
* "portrait mode" groups the shots taken with the depth camera
* "very blurry" finds the shots worth deleting first

Measured on my own library, iPhone 13 Pro Max, Debug build (TestFlight and App Store builds should be faster):

* embed a photo in 64 ms, a query in 6.7 ms
* typed search over all 29,682 vectors: 24 to 29 ms warm, embedding included; preset piles 8 to 15 ms
* index the whole 29,685-item library in 75.8 minutes, 0 failures (about 27 minutes of that was the pause while the phone is hot, so an unpaced run is faster)
* warm search holds about 630 MB

What was hard: Core ML loads the model as one ~1 GB blob, past what iOS gives a Neural Engine model, so it's 9 functions compiled one at a time (first launch ~20 minutes, then iOS caches it, and deletes that cache if free space drops under ~2 GB). Search started at ~300 ms per query because of one full scored sort per prompt; a single vDSP matrix multiply plus integer-aligned rows got it to 14.5 ms.

Every step of the conversion is tested against Google's original model across 8 stages, with gates that fail the build if the vectors drift. No vibes, cosine checks.

License, to be precise: the conversion repo and the Swift package are Apache 2.0, so anyone can run EmbeddingGemma 2 on Apple hardware (GitHub: Delavalom/embeddinggemma-coreml, HF: delavalom/embeddinggemma-2-coreml). The app code is source-available under PolyForm Noncommercial (GitHub: Delavalom/roll-ios), readable and usable for yourself but not for selling.

The app itself is in TestFlight [status placeholder]. If you'd rather build on the embedding model than the app, the Swift package is the part to take.

I'd really appreciate feedback, especially on the conversion gates and the search benchmark, and I'll answer questions about the port.
