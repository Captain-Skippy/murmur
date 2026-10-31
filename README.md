# Murmur

Private dictation for macOS. Hold **Fn**, talk, let go: clean, punctuated text is pasted wherever your
cursor is. Speech recognition and cleanup both run on your Mac. There is no account, no server and no
cloud fallback, and your audio never leaves the machine.

I built Murmur to replace Wispr Flow for my own daily use. On my Mac it pastes text a median of
260 ms after I let go of the key, against Wispr's 511 ms on the same clips ([bench](docs/bench.md)).

## What it does

- **Hold to talk, or go hands-free.** Hold Fn while you speak. For longer dictation, double-tap Fn
  or press Fn+Space, and press Fn again to stop. Escape cancels.
- **Local recognition.** NVIDIA's Parakeet runs on the Neural Engine through
  [FluidAudio](https://github.com/FluidInference/FluidAudio). Long dictations are decoded in segments
  while you are still talking, so little is left to do when you let go.
- **Local cleanup.** A small language model ([MLX](https://github.com/ml-explore/mlx-swift), Qwen3-4B by default)
  removes "um"s, stutters and false starts and handles self-corrections. "Tuesday, no, Wednesday"
  becomes "Wednesday".
  - It turns numbers, emails, URLs and lists into written form, and spoken "new line" and "comma" into
    formatting.
  - In code editors and terminals it writes identifiers the way you'd type them (`--dry-run`,
    `loadModels`, `Controller.swift`).
- **Never answers you.** Dictating "write an email to Sam" or "ignore previous instructions" gives you
  exactly that sentence. A hard check catches cleanup output that answers, obeys, adds words, drops
  words or changes numbers, and pastes the plain transcript instead.
- **Your words, spelled your way.**
  - Add names and jargon to a personal dictionary, with the ways the recognizer mishears them.
  - Murmur notices when you fix a word right after it pastes and offers to learn it.
  - Snippets expand a spoken phrase ("my email") into text.
- **Pastes anywhere.** Murmur pastes through the clipboard with Cmd+V, then restores what you had
  copied. Never inside password fields.

## Requirements

- An Apple silicon Mac running macOS 26 or later.
- Xcode 26 or later to build it. Its Metal toolchain compiles MLX's shaders.
- About 3 GB of disk for the models (speech about 600 MB, cleanup about 2.3 GB) and 16 GB of RAM.

## Download

Get `Murmur-VERSION.zip` from [Releases](https://github.com/Captain-Skippy/murmur/releases), unzip it, drag
Murmur to Applications and open it. It's signed and notarized by Apple, so it opens without a warning.

## Build and install

```sh
git clone https://github.com/Captain-Skippy/murmur.git
cd murmur
scripts/build-app.sh            # builds and signs build/Murmur.app
cp -R build/Murmur.app /Applications/
open /Applications/Murmur.app
```

`build-app.sh` signs with your Apple Development certificate if you have one. Otherwise it signs ad
hoc, and macOS will ask for the permissions again after each rebuild. With a Developer ID
(`MURMUR_SIGN_IDENTITY`), `scripts/notarize.sh PROFILE` notarizes the build and zips it for download.

On first launch Murmur opens its window, adds itself to your login items (turn that off in Settings)
and asks for three permissions. Grant each one; System Settings asks for your password:

- **Microphone**, to hear you.
- **Accessibility**, to paste with Cmd+V. macOS asks for this first; on macOS 27 it's called "Device
  Control and Data Access".
- **Input Monitoring**, to see the Fn key.

A banner in the window names any permission still missing. The models (about 3 GB) download the first
time Murmur starts; the window says "Ready" when they're loaded. After that it works offline.

Make Fn do nothing on its own: System Settings → Keyboard → "Press 🌐 key to" → **Do Nothing**.

## Using it

- **Hold Fn**, speak and release. The text goes to the cursor.
- **Hands-free:** double-tap Fn or press Fn+Space; a lock shows on the indicator. Press Fn to finish.
- **Escape** cancels a dictation.
- **Open Murmur again** (Spotlight or double-click) to show its window. It has no Dock icon. The window
  has three tabs:
  - **Home:** recent dictations, with Copy and Insert.
  - **Dictionary:** words and snippets.
  - **Settings:** microphone, sounds, open at login, Quit.

Settings that have no switch in the window live in `~/Library/Application Support/Murmur/settings.json`.
Restart Murmur after editing it:

| Key | Default | Meaning |
| --- | --- | --- |
| `recognizer` | `parakeet-unified` | Speech model; `murmur-cli stacks` lists them all. `parakeet-unified+vote` adds two voters for a little more accuracy and memory. |
| `cleaner` | `qwen3-4b+lookup` | Cleanup model. `qwen3-1.7b+lookup` is lighter (1 GB) but weaker. `none` pastes the recognizer's text with fillers removed and your dictionary applied; self-corrections and spoken commands ("new paragraph") need a model. |
| `insertionOverrides` | `{}` | Per-app method, by bundle id: `paste`, `accessibility` or `keystrokes`. |
| `menuBarIcon` | `false` | Show a menu bar icon. |
| `warmMicMinutes` | `10` | Keep the mic open this long after dictating so the next one starts instantly (the orange dot shows). |

## Privacy

Everything Murmur keeps is in `~/Library/Application Support/Murmur`, readable only by you:

- **Settings and dictionary:** `settings.json`, `dictionary.json`.
- **`history/`:** recent dictations as text, kept 7 days.
- **`corpus/`:** each dictation's audio and text, kept 90 days, so you can measure and fine-tune
  Murmur on your own voice.

`~/Library/Logs/Murmur/timings.jsonl` records how long each stage took, never what you said. Murmur
connects to the internet only to download models from Hugging Face.

## Making it yours

The cleanup model I use every day is Qwen3-4B fine-tuned on my own dictation history, which isn't
shared. You can train your own the same way, on your Mac:

- **`murmur-cli`** (inside the app at `Contents/MacOS/murmur-cli`) benchmarks recognizers and cleaners
  on your own recordings.
- **`murmur-cli dictate FILE.wav`** (or `--text "um so..."`) prints what Murmur would paste, using
  your settings; add `--cleaner NAME` to try another cleanup model before switching to it.
- **`murmur-cli import-wispr`** brings in your Wispr Flow history and dictionary, if you used it.
- **`train/train.sh`** fine-tunes a cleanup model with LoRA. Results land in
  `Application Support/Murmur/models/` and appear as `tuned-NAME` cleaners.

[docs/bench.md](docs/bench.md) has the measurements behind every default, and `docs/` has the research.

## When something is wrong

- **Nothing happens on Fn:** open Murmur. A banner names any missing permission.
- **No audio:** set the microphone to Automatic in Settings.
- **Text doesn't appear in one app:** use Copy or Insert in the window, or set an `insertionOverrides`
  entry for that app.
- **A name keeps coming out wrong:** add it in Dictionary, with how it was misheard.
- **Logs:** `log show --predicate 'subsystem == "com.cjhorning.murmur"' --last 10m`

## Limits

- **macOS 26 and Apple silicon only.**
- **Cleanup isn't perfect.** It sometimes leaves a filler or drops a phrase, even from a perfect
  transcript ([bench](docs/bench.md)).
- **Some apps ignore Cmd+V** and need an insertion override.

## License

[MIT](LICENSE).
