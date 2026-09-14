export function invocation(provider, prompt, spec = {}) {
  if (!['claude', 'codex', 'grok', 'custom'].includes(provider)) throw new Error(`Unknown evaluation provider: ${provider}`);
  const defaults = provider === 'codex' ? ['exec', '--json', prompt]
    : provider === 'grok' ? ['-p', prompt, '--output-format', 'streaming-json']
    : ['-p', prompt, '--output-format', 'json'];
  if (provider === 'custom' && (!spec.command || !spec.args?.includes('{prompt}'))) throw new Error('Custom evaluations need command and args containing {prompt}.');
  const args = spec.args ? spec.args.map(arg => arg === '{prompt}' ? prompt : arg) : [...defaults, ...(spec.claudeArgs || [])];
  if (!Array.isArray(args) || args.some(arg => typeof arg !== 'string')) throw new Error('Evaluation args must be strings.');
  return { command: spec.command || provider, args };
}
export function normalizeResult(stdout, elapsed) {
  let events;
  try { events = [JSON.parse(stdout)]; }
  catch { events = stdout.split(/\r?\n/).filter(Boolean).flatMap(line => { try { return [JSON.parse(line)]; } catch { return []; } }); }
  let result = '', usage = {}, turns;
  for (const event of events) {
    if (typeof event.result === 'string') result = event.result;
    else if (event.type === 'item.completed' && event.item?.type === 'agent_message') result += `${result ? '\n' : ''}${event.item.text || ''}`;
    if (event.usage) usage = event.usage;
    if (typeof event.num_turns === 'number') turns = event.num_turns;
  }
  return { result, usage, num_turns: turns, duration_ms: elapsed, parsed: events.length > 0 };
}
