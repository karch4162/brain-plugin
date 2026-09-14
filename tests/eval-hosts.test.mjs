import { test } from 'node:test';
import assert from 'node:assert/strict';
import { invocation, normalizeResult } from '../eval/hosts.mjs';
test('eval host launchers keep prompts as a single argument', () => {
  const prompt = 'Explain $(echo danger) and `literal`';
  for (const provider of ['claude', 'codex', 'grok']) {
    const spec = invocation(provider, prompt, {});
    assert.ok(spec.args.includes(prompt));
    assert.equal(spec.command, provider);
  }
});
test('Codex events normalize answer and usage without inventing missing metrics', () => {
  const raw = [{ type: 'item.completed', item: { type: 'agent_message', text: 'Answer' } },
    { type: 'turn.completed', usage: { input_tokens: 100, output_tokens: 20 } }].map(JSON.stringify).join('\n');
  const result = normalizeResult(raw, 23);
  assert.equal(result.result, 'Answer'); assert.equal(result.usage.input_tokens, 100);
  assert.equal(result.duration_ms, 23);
  assert.equal(normalizeResult('{}', 1).usage.input_tokens, undefined);
});
