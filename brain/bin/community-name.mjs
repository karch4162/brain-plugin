// community-name.mjs — the ONE place a community label folds into a filesystem
// name. Imported by label-communities.mjs (which mints labels and writes report
// hub links) and build-community-notes.mjs (which writes the stub files those
// links must land on).
//
// WHY THIS EXISTS
// These two scripts each carried their own fold — label-communities' sanitizeLabel
// and build-community-notes' safeName. They agreed on the common cases by
// convention, not by construction, and had already drifted on the edges:
//   - `"`            sanitizeLabel → ' ' (space), safeName → '-'
//   - trailing `. `  sanitizeLabel kept it, safeName stripped it
//   - length         sanitizeLabel truncated at 60, safeName did not
// Any divergence is silent and expensive: the report emits [[_COMMUNITY_<fold A>]]
// while the stub lands at `_COMMUNITY_<fold B>.md`, so the link becomes a ghost
// node and the wiki cluster detaches from the code graph — exactly the failure
// build-community-notes exists to prevent.
//
// Note the fold is NOT the only source of mismatch: graphify's own report writer
// folds differently again (it DELETES `/` where we replace it, so
// "Offline Sync / Tab Charging" becomes the target "Offline Sync  Tab Charging",
// with a double space). Report targets we do not author are still reconciled by
// the Obsidian `aliases` in each stub — see build-community-notes' header. This
// module removes the drift we control; the alias layer absorbs the rest.

// Fold a label to a filesystem- and wikilink-safe name.
//   - `\ / : * ? " < > | # ^ [ ]` are illegal in Obsidian links and/or on Windows.
//     `/` and `\` MUST become a visible separator rather than vanish, or Obsidian
//     reads the remainder as a folder path.
//   - Trailing dots/spaces are stripped: Windows silently drops them from
//     filenames, which would desync the file from the link that named it.
export const foldCommunityName = (s) =>
  String(s ?? '')
    .replace(/[\r\n]/g, ' ')
    .replace(/[\\/:*?"<>|#^[\]]/g, '-')
    .replace(/\s+/g, ' ')
    .trim()
    .replace(/[. ]+$/, '')
    .trim();

// Fold + bound the length, for a label being MINTED (agent-named or derived).
// Applied before the label is written into a report heading, so the heading and
// the filename derived from it can never disagree on length.
export const LABEL_MAX = 60;
export const foldLabel = (s) =>
  foldCommunityName(s)
    .slice(0, LABEL_MAX)
    .trim()
    .replace(/[. ]+$/, '')
    .trim();

// The stub filename basename (and therefore the wikilink target) for a label.
export const stubBase = (label) => `_COMMUNITY_${foldCommunityName(label)}`;

// Case-fold key. Windows and macOS filesystems are case-insensitive, and
// Obsidian resolves links case-insensitively, so two names that differ only by
// case are the SAME name for every purpose that matters here.
export const nameKey = (s) => String(s ?? '').toLowerCase();
