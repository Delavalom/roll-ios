# First comment (LinkedIn) + posting checklist

## First comment text

Repo, model and measurements:

* Model, Apache 2.0, on Hugging Face: https://huggingface.co/delavalom/embeddinggemma-2-coreml
* The Core ML conversion and Swift package (Apache 2.0): https://github.com/Delavalom/embeddinggemma-coreml
* The app source (PolyForm Noncommercial), with every measurement in docs/investigations: https://github.com/Delavalom/roll-ios
* Site: https://roll.delavalom.com

## Posting checklist

1. Model is unpublished and roll-ios is still private per ROLL-HANDOFF.md, so before posting: publish the HF repo, make the repos public, and confirm the URLs resolve from a logged-out browser. Post the links only once they work.
2. Attach the video in the Kleo app by hand: launch video, `docs/design/ask-roll/video/ask-roll-demo.mp4` (51 s, voiceover + music, the storyboard one). Keep `showcase/roll-demo.mp4` (57 s screen recording) for a follow-up post or a comment a day later; one video per post.
3. Reddit first, then LinkedIn, distance them by a day or two so the LinkedIn post can honestly say "it took off on r/LocalLLaMA".
4. Fill the [status placeholder] in reddit-post.md with the real TestFlight state at posting time.
5. ADR-0005 rule respected: every number in the post is measured, the post discloses the Debug build, and the app never claims "Neural Engine" without measurements backing it.

## Why the body is shaped this way (vs the Kleo draft)

* No labelled sections ("The numbers:", "What was hard:") because that structure is the main AI tell; the DigUp posts write numbers straight into prose.
* The hook is a concrete moment on a real library instead of "I got X running on Y", which reads like a changelog.
* DigUp is credited by name in line 2 of the LinkedIn post, which preempts the "shameless copy" comment and earns goodwill from that audience.
* The license honesty sits at the end, stated plainly instead of defensively.
* One question at the close, one promise (links in comments), nothing else after the promise.
