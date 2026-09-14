import { existsSync, readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { getSession, startSession } from './vaults.mjs';
import { readJson, writeJson, locked, git, bashScript, advanceSessionPin } from './runtime.mjs';

const hash = text => createHash('sha256').update(text).digest('hex');
const content = path => existsSync(path) ? readFileSync(path) : Buffer.alloc(0);
export function prepareSave(vault, id) {
  const session = startSession(vault, id);
  return locked(join(session.path, '.brain/write.lock'), () => {
    if (git(session.path, ['status', '--porcelain', '--', 'wiki/hot.md'])) throw new Error('hot.md has unpublished edits. Resolve them before preparing a replacement.');
    const preparation = randomUUID();
    const hot = content(join(session.path, 'wiki/hot.md'));
    bashScript('write-hot.sh', ['--pin'], session.path, id);
    const record = { preparation, session: id, head: git(session.path, ['rev-parse', 'HEAD']), hotHash: hash(hot), date: new Date().toISOString().slice(0, 10) };
    writeJson(join(session.path, '.brain/save-preparation.json'), record);
    return { state: 'prepared', ...record, path: session.path, hot: hot.toString('utf8'),
      input: { preparation, title: 'Session title', summary: 'What changed and why', decisions: [], pending: [], files: [], hot: 'Updated cache, at most 500 words' },
      note: 'Prepare the semantic summary in a JSON file. apply records session continuity only; graph refresh and curated-note changes remain separate workflows.' };
  });
}
function validate(input) {
  if (!input || typeof input.preparation !== 'string' || !/^[a-f0-9-]{36}$/.test(input.preparation)) throw new Error('A save preparation token is required.');
  for (const field of ['title', 'summary', 'hot']) if (typeof input[field] !== 'string' || !input[field].trim()) throw new Error(`${field} must be nonempty text.`);
  if (/[\r\n]/.test(input.title) || input.title.length > 160) throw new Error('Title must be a single line of at most 160 characters.');
  if (input.hot.trim().split(/\s+/).length > 500) throw new Error('hot exceeds the 500-word context budget.');
  for (const key of ['decisions', 'pending', 'files']) if (input[key] && (!Array.isArray(input[key]) || input[key].some(x => typeof x !== 'string'))) throw new Error(`${key} must be an array of strings.`);
}
export function applySave(vault, id, input) {
  validate(input);
  const session = getSession(vault, id);
  if (!session || session.endedAt) throw new Error('Start an active session and prepare the save first.');
  return locked(join(session.path, '.brain/write.lock'), () => {
    const journalPath = join(session.path, '.brain/operations', `${input.preparation}.json`);
    const inputHash = hash(JSON.stringify(input));
    let journal = readJson(journalPath);
    if (journal && journal.inputHash !== inputHash) throw new Error('This save token already belongs to different content. Prepare a new save.');
    if (journal?.commit) return { state: 'saved-locally', commit: journal.commit, path: session.path, repeated: true, graphRefresh: 'not-performed', publication: 'not-pushed' };
    const prep = readJson(join(session.path, '.brain/save-preparation.json'));
    if (!prep || prep.preparation !== input.preparation || prep.session !== id) throw new Error('Save preparation is missing or superseded. Prepare again.');
    const currentHead = git(session.path, ['rev-parse', 'HEAD']);
    // A crash after the commit but before journaling is recovered by its unique trailer.
    if (currentHead !== prep.head) {
      const msg = git(session.path, ['log', '-1', '--format=%B']);
      if (journal && msg.includes(`Brain-Operation: ${input.preparation}`)) {
        journal.commit = currentHead; writeJson(journalPath, journal);
        advanceSessionPin(session.path, id, prep.head, currentHead);
        return { state: 'saved-locally', commit: currentHead, path: session.path, recovered: true };
      }
      throw new Error('Session HEAD moved after preparation; inspect and prepare again.');
    }
    const hotPath = join(session.path, 'wiki/hot.md');
    const desiredHot = input.hot.endsWith('\n') ? input.hot : input.hot + '\n';
    const currentHash = hash(content(hotPath));
    if (currentHash !== prep.hotHash && (!journal || currentHash !== hash(desiredHot))) throw new Error('hot.md changed after preparation; the new content was preserved.');
    journal ||= { inputHash, preparation: input.preparation };
    writeJson(journalPath, journal);
    const staged = join(session.path, '.brain/save-hot.md'); writeFileSync(staged, desiredHot);
    if (currentHash === prep.hotHash) bashScript('write-hot.sh', ['--write', staged.replace(/\\/g, '/')], session.path, id);
    bashScript('check-hot-budget.sh', [], session.path, id);
    const bullets = values => (values?.length ? values.map(v => `- ${v}`).join('\n') : '- None.');
    const log = `# ${prep.date} — ${input.title}\n\n## What happened\n${input.summary}\n\n## Decisions\n${bullets(input.decisions)}\n\n## Pending / next steps\n${bullets(input.pending)}\n\n## Files touched\n${bullets(input.files)}\n\n<!-- brain-operation: ${input.preparation} -->\n`;
    const logName = `logs/${prep.date}-${input.preparation}.md`;
    mkdirSync(join(session.path, 'logs'), { recursive: true });
    const logPath = join(session.path, logName);
    if (existsSync(logPath) && readFileSync(logPath, 'utf8') !== log) throw new Error('Session log changed outside this save; preserved it for review.');
    writeFileSync(logPath, log);
    const operations = join(session.path, 'wiki/log.md');
    const previous = existsSync(operations) ? readFileSync(operations, 'utf8') : '';
    const marker = `<!-- brain-operation: ${input.preparation} -->`;
    if (!previous.includes(marker)) writeFileSync(operations, `${previous}${previous && !previous.endsWith('\n') ? '\n' : ''}- ${prep.date} — ${input.title} ${marker}\n`);
    const message = bashScript('vault-commit.sh', ['--pin', `${session.branch}:${prep.head}`, '-m', `docs(brain): ${input.title}\n\nBrain-Operation: ${input.preparation}`, logName, 'wiki/hot.md', 'wiki/log.md'], session.path, id);
    journal.commit = git(session.path, ['rev-parse', 'HEAD']); writeJson(journalPath, journal);
    advanceSessionPin(session.path, id, prep.head, journal.commit);
    return { state: 'saved-locally', commit: journal.commit, path: session.path, message, graphRefresh: 'not-performed', publication: 'not-pushed' };
  });
}
