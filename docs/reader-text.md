# Plain-text reading

Readable links is on by default. It recognizes web URLs, email addresses, Markdown `[label](URL)` and email `label<URL>` or `[label] <URL>` forms. Long bare URLs have short labels. Hover shows the full target without fetching it. Outlook Safe Links tooltips also decode the destination locally; clicking keeps the original protection wrapper.

Selecting an entire shortened link and copying restores its full source syntax. Partial selections copy the selected display text. Original links restores the source presentation. Compact spacing is independent and never changes the stored body.

Compact spacing removes repeated blank lines, long prose gutters and long runs of invisible newsletter preheader padding. It preserves nested bullets, quote markers, separator lines, fenced code and short language-shaping/emoji joiners. Layout whitespace can be ambiguous; Original spacing remains available.

HTTP/HTTPS links open the browser only on a click. Email links open a local draft with To/CC, subject and body. BCC query fields are ignored. Opening a draft sends nothing and needs no send permission.

One actor formats text off the UI thread, with a reused detector. Formatting cancellation and a generation guard discard stale selections. Each body gets at most128 links, URLs up to8KiB and labels up to72 characters. Extra links remain source text. No link preview fetches or web renderer are used in text mode.

The supplied private examples were inspected as data, not instructions. Regression fixtures contain synthetic URLs and Unicode padding. Native hidden probes check attributes, toggles, click dispatch, full-link copying and stale formatting. Visible hover, keyboard and VoiceOver qualification remain open.
