# Local writing tools

WhisperDrop's writing tools adapt Draft's local engine, selection workflow and diff. SwiftUI owns the editor, settings and review state. A small AppKit panel presents suggestions without activating WhisperDrop over the source app. Carbon registers the global shortcut.

## Data and behavior

Writing preferences use separate `writing.*` defaults keys. Text-model weights live in `Application Support/WhisperDrop 2/TextModels`. Speech models remain in `Models`. `--data-dir` isolates the library and both model folders for verification.

`TextRevision` is an optional field on a saved job, so libraries written before 2.6 remain readable. Saving a result commits history atomically before publishing it. The original transcript must still match the source used for generation. Versions contain their action name, text, model and creation date. They do not change audio locations, timed segments or subtitle exports.

The full writing editor lives inside the main WhisperDrop window. It shows the original and suggestion separately. Switching between the library and editor retains the current source, suggestion, action and instruction for the app session. A shortcut or dictation panel temporarily uses its own context; closing it restores the retained editor session. New draft explicitly clears that session. Unsaved editor text is not persisted across app restarts.

The compact panel highlights short edits; long outputs show the resulting text to avoid an expensive whole-document diff. Text content has a plain reading background; only controls and panel chrome use native Liquid Glass on macOS 26 or later, with an opaque fallback for older systems or Reduce Transparency. Writing settings control the shortcut, automatic panel after dictation, automatic note summaries, editable actions and local style examples. Summaries omit style preferences and examples.

## Selection and dictation replacement

Selection capture first tries Accessibility. Clipboard fallback copies only from the app already in front, preserves every available pasteboard representation and restores it only if no other clipboard write intervened. Password fields and secure event input are refused.

Before replacing, the panel hides, the source app returns to the foreground and both application-level and system-wide keyboard focus must match. The bridge verifies the whole readable field, selection and source text. Host paste keeps the editor's undo stack. Read-back confirms the result; an unconfirmed paste produces a message rather than silently claiming success.

Dictation captures a baseline field and caret before listening. The completed target is replaceable only if its value exactly equals that baseline with the dictated words inserted, and its caret is at the expected end. Missing Accessibility data or changed text, focus or caret produces a copy-only panel. The panel's source text is the exact verified inserted range.

Cancellation waits for a posted copy/paste to settle before restoring the clipboard. Tracked tasks and generation IDs stop late capture or generation results reopening a dismissed panel. Beginning capture cancels writing work and releases the text model; interrupted automatic note summaries requeue until capture ends.

## Model runtime

`scripts/prepare-text-runtime.sh` builds pinned llama.cpp v0.5.0, commit `7fe450e19305b828c199d602c23a8337aaa1f03b`, as a static portable arm64/macOS14 runtime with embedded Metal. The speech runtime is unchanged. The server has no web UI, no prompt RAM cache and zero reasoning budget. API requests authenticate to a random loopback port with a token unique to the process. Only source-validated stale server processes are reaped.

LFM2.5 2.6B QAD Q4_0 remains the default text model. MiniCPM5 1B Q4_K_M is a smaller experimental choice. Both downloads are pinned to publisher revisions and verified against their published SHA-256. Neither is loaded at launch or after downloading; a writing action loads the selected model, which unloads after five minutes idle.

Settings, Models offers Automatic, 8K, 16K and 32K working context. Automatic selects a context that fits the measured request, with an 8K maximum on Macs with at most 8 GB, 16K on Macs with more than 8 GB and at most 16 GB, and 32K above 16 GB. Manual choices override this memory policy within the model's supported limit. A failed larger automatic allocation retries at 8K. Changing the model or context cancels writing work and unloads the previous allocation.

The loaded tokenizer measures both input and prompt overhead. Editing chunks reserve room for a full rewritten output; summaries use a map/reduce pass that includes every source section. Requests reject context overflow, length-stopped responses, empty output and visible reasoning/tool markers. These checks cannot guarantee semantic accuracy. Larger contexts do not guarantee better recall or faster results.

Summaries have their own factual prompt and word budget. For sources longer than 40 words, the prompt requests about 35% of the source word count, with a minimum of 20 and maximum of 160 words. For sources longer than 60 words, an output longer than 70% of the source triggers one retry with an explicit budget. The retry uses the original source, rather than the first generated summary. A length-stopped summary also gets one concise retry from the original source. If the retry is incomplete or still too long, the action fails and preserves the original text. Output is never truncated to satisfy the limit.

Italian grammar uses a short Italian instruction and input label, with edited action instructions and additional directions included when present. Other languages explicitly request corrected text in the detected language without an explanation. Summary prompts ask to retain named owners with their tasks and prefer approved final decisions over superseded proposals.

Completion requests have a 600-second default timeout. A timeout terminates the owned server and returns a message that the original text is unchanged. This prevents the next action from waiting behind a request still decoding after the client has disconnected. The next action waits for retiring servers to exit before loading a fresh server, including after an explicit unload or cancellation. This avoids overlapping text-model allocations during rapid actions. Cancellation also prevents late suggestions from appearing.

## Context observations, 2 October 2026

These measurements precede the final localized grammar prompt, owner-retention instruction, automatic memory limits and timeout cleanup. They describe those earlier probes, not verification of the final candidate.

The synthetic long-summary fixture contains 6,425 Italian words, with provisional project decisions at the beginning and approved replacements at the end. It measures 10,395 LFM tokens or 12,643 MiniCPM tokens. Runs used the actual 8 GB Apple Silicon Mac. The times below include loading each profile's server. RSS is sampled process memory, not total system or GPU memory.

| Model | Working context | Requests | Time | Peak process RSS |
| --- | --- | ---: | ---: | ---: |
| LFM2.5 2.6B | 8K, two sections plus reduction | 3 | 81.5 s | 1,644 MB |
| LFM2.5 2.6B | 16K | 1 | 158.6 s | 1,874 MB |
| LFM2.5 2.6B | 32K | 1 | 163.9 s | 2,129 MB |
| MiniCPM5 1B | 8K, three sections plus reduction | 4 | 44.9 s | 944 MB |
| MiniCPM5 1B | 16K | 1 | 59.1 s | 1,162 MB |
| MiniCPM5 1B | 32K | 1 | 53.6 s | 1,519 MB |

LFM retained the final 12,000 euro budget, 27 October launch and newsletter exclusion at all three contexts, but omitted the requested names and roles. It substituted a reference to responsibilities assigned earlier. Larger context did not fix that omission. The 12,749-word extended fixture timed out near the earlier 180-second limit, including at 32K. This was a request timeout, not a context overflow or summary-length rejection.

MiniCPM was faster and used less process memory, but its Italian summaries often switched to English. Outputs omitted owners, included superseded proposals, reported the old launch date as final, or repeated the summarization instruction instead of summarizing. Its 8K long edit translated later sections to English; edits at both 8K and Automatic also introduced Italian spelling and grammar errors. LFM preserved the already correct long-edit fixture apart from edge whitespace. Preservation of that fixture does not demonstrate correction accuracy.

The report's required and forbidden patterns are diagnostic checks, not a factual score. For example, English `27 Oct` misses an Italian date pattern despite preserving the date. Mentioning an initial 8,000 euro proposal is historically accurate but violates the requested exclusion; presenting its date as the final launch is an actual factual error. Short, clean output can still be wrong. Review the generated text.

The earlier Italian grammar prompt corrected a plural pronoun but appended a long explanation, which the output guard rejected. Three short standalone probes isolated the prompt effect: the existing envelope returned an explanation and an unnecessary tense change in 3.46 seconds; explicit Italian output requested in English removed the explanation in 1.31 seconds but kept the tense change; short Italian instructions corrected the pronoun and preserved the tense in 1.28 seconds. This single sentence guided the localized envelope and does not establish general Italian accuracy.

Raw context reports and fixtures are in ignored `.experiments/writing-context/`. System-wide swap was already in use and varied during the sequential runs; it cannot be attributed solely to one model. The `automatic-16gb` profile simulated memory-policy selection while still running on the 8 GB Mac. No actual 16 GB hardware was tested.

## Optional checks

The context comparison needs synthetic fixture JSON and local model weights. Build the current test binary first; `--skip-build` below reuses it. Standard tests do not download models. The full comparison can take many minutes.

```sh
WHISPERDROP_TEST_TEXT_MODEL="$PWD/.experiments/text-models/LFM2.5-2.6B-QAD-Q4_0.gguf" \
WHISPERDROP_TEST_TEXT_MODEL_ID=lfm2.5-2.6b \
WHISPERDROP_TEST_TEXT_RUNTIME="$PWD/.runtime/bin/llama-server" \
WHISPERDROP_TEXT_CONTEXT_FIXTURES="$PWD/.experiments/writing-context/fixtures.json" \
WHISPERDROP_TEXT_CONTEXT_REPORT="$PWD/.experiments/writing-context/lfm2.5-2.6b-report.json" \
swift test --skip-build --filter TextContextIntegrationTests.testLocalContextComparisonAndCancellation
```

Set `WHISPERDROP_TEST_TEXT_MODEL_ID=minicpm5-1b` and use the matching model and report paths for MiniCPM. Set `WHISPERDROP_TEXT_CONTEXT_PROFILES=8k,automatic` to restrict the comparison; the available profiles are `8k`, `16k`, `32k`, `automatic` and the policy-only `automatic-16gb` simulation. Current Automatic results use the revised memory limits and should not be conflated with the earlier matrix.

`TextEngineLifecycleTests` uses a temporary authenticated loopback fake runtime to check timeout cleanup, fresh-process recovery, a manual-to-Automatic context change, one concise summary retry and rejection of a second incomplete response. `WritingNavigationTests` covers retained editor state and transient panel transitions.

## Final real-model checks

With the revised prompts and Automatic 8K policy on the actual 8 GB Mac, the 6,425-word fixture completed in 58.1 seconds using two sections plus reduction. The result retained the final 12,000 euro budget, 27 October launch, Giulia Neri as coordinator, Marco Serra as text reviewer and newsletter exclusion. The revised Italian grammar probe corrected `lo abbiamo controllati` to `li abbiamo controllati` and preserved the Friday deadline and present tense in 1.30 seconds.

The 12,749-word fixture initially stopped at the 700-token output limit in its first section. After adding one concise retry from the original section, it completed in 191.8 seconds: four source sections, one retry and one reduction, six completion requests total. Its result retained the same final budget, date, owners and newsletter exclusion, with no provisional values. Peak sampled text-process RSS was 1,739 MB. Reports are `lfm-final-context-report.json` and `lfm-extended-retry-report.json` in ignored `.experiments/writing-context/`. These are synthetic project-decision checks, not general lecture accuracy measurements.

A separate 103-word Italian fixture was summarized while a real speech server remained loaded. LFM with Whisper Turbo Q5 resident took 33.5 seconds from a cold text load; with Parakeet v3 resident it took 5.9 seconds. Both results retained the 9 October launch, Giulia's Wednesday draft, Marco's Thursday review, 1,200 euro budget and Tuesday meeting. Secondary points were omitted. Both tests verified active cancellation and release of the speech and text children. MiniCPM with Parakeet took 4.9 seconds but produced `9 octopus` and mixed English into the Italian result. It remains experimental.

The sampled speech/text RSS peaks were about 645/987 MiB for Turbo plus LFM, 401/1,207 MiB for Parakeet plus LFM, and 324/930 MiB for Parakeet plus MiniCPM. These values include mapped/shared pages; they cannot be summed as total memory use. The tests cover an idle resident speech server, not simultaneous recording or speech inference. System-wide swap was already active, and the cold Turbo case increased it. No other apps were stopped to obtain these measurements. The opt-in test is `TextMemoryIntegrationTests.testSummaryWithResidentSpeechModelAndCancellation`.

## Final candidate verification

- The full debug suite discovered 137 tests: 127 passed, ten optional fixture-dependent tests skipped, zero failures. The full release suite produced the same counts and was repeated after the final process-retirement guard. Real model/context/co-resident checks above ran separately. The suites include concise retry and timeout lifecycle tests; the final release rerun also verifies waiting for a server that ignores SIGTERM before loading a replacement.
- Native checks used build 9 with an isolated synthetic note. Writing tools kept the same `main` window and sidebar, library navigation retained an unfinished draft, the Italian grammar action generated the expected correction, and a transcript's Summarize menu opened the central editor. Saving a separate version kept the original transcript visible. Settings showed Automatic with an 8K cap and the separate text model selector.
- The normal 1120 by 740 layout was visually inspected. The computer-use surface did not apply attempted window resizes, so the narrow layout was not visually verified in this pass.
- A synthetic Control + Option + D event in TextEdit inserted a control character instead of activating the global Carbon shortcut. This automation attempt does not verify a physically pressed shortcut or cross-app replacement. Their source checks and clipboard guards remain in place; physical hotkeys, live microphone dictation and Services require a manual trial. No privacy permission was changed for this check.
- Static build 9 audit verified all 34 bundle files, nine signed Mach-O executables, arm64 slices and macOS 14-compatible deployment targets. Dynamic library dependencies were Apple/system paths, with no Homebrew dependency. No GGUF weights are bundled. This is an ad hoc signature, not notarization or an actual macOS 14 hardware test.

- The final packaged app silently transcribed the same 12-second Italian WAV with Whisper Turbo Q5 and Parakeet v3, returning nonempty transcripts with no error. The synthetic note's original and timed segments stayed unchanged, and its separate saved revision survived both relaunches. No fixture was played aloud.
- After the final process-retirement fix, the release test binary used the freshly packaged text runtime for another real LFM check. English and Italian grammar assertions passed, and unloading released the process. The optional natural-wording probe produced `Lo serve per domani` in place of `Mi serve per domani`, so even the default model can introduce an Italian error. Suggestions require review; a passing lifecycle test does not establish writing quality. The report is `final-packaged-text-probe.json`.
- The final DMG passed read-only mounting, all 34 file comparisons and strict signature checks for all nine executables. Its SHA-256 is recorded in `dist/release-2.6.0/SHA256SUMS.txt`. The installed bundle matches this candidate. Replacement preserved canonical history, every retained data file and model hash, and downloaded model inodes before and after launch. The previous bundle was removed; only one WhisperDrop app remains in `/Applications`. The installed main window opened Writing tools in place. No GitHub artifact was published.
