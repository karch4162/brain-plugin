import { existsSync, readFileSync, lstatSync, readlinkSync } from 'node:fs';
import { join, resolve, relative, isAbsolute } from 'node:path';
import { createHash } from 'node:crypto';
import { git, readJson, writeJson } from './runtime.mjs';

const hash = value => createHash('sha256').update(value).digest('hex');
function fingerprint(root, scopes) {
  root = resolve(root);
  if (!Array.isArray(scopes) || !scopes.length) throw new Error('At least one recorded source scope is required.');
  for (const scope of scopes) {
    if (typeof scope !== 'string' || !scope || isAbsolute(scope) || scope.startsWith('-') || scope.startsWith(':') || scope.split(/[\\/]/).includes('..')) throw new Error('Scopes must be literal paths within the repository.');
  }
  const paths = [...new Set(git(root, ['--literal-pathspecs', 'ls-files', '--cached', '--others', '--exclude-standard', '-z', '--', ...scopes]).split('\0').filter(Boolean))].sort();
  const inputs = [];
  for (const path of paths) {
    if (path === 'graphify-out' || path.startsWith('graphify-out/') || path.startsWith('.brain/')) continue;
    const full = resolve(root, path);
    if (relative(root, full).startsWith('..')) throw new Error('Graph input escaped its root.');
    if (!existsSync(full)) { inputs.push([path, 'deleted']); continue; }
    const stat = lstatSync(full);
    if (stat.isSymbolicLink()) inputs.push([path, hash(readlinkSync(full))]);
    else if (stat.isFile()) inputs.push([path, hash(readFileSync(full))]);
  }
  const ignore = join(root, '.graphifyignore');
  const ignoreHash = existsSync(ignore) ? hash(readFileSync(ignore)) : null;
  return { hash: hash(JSON.stringify({ scopes, inputs, ignoreHash })), files: inputs.length, ignoreHash };
}
export function prepareGraph(root, scopes, extractor) {
  if (!extractor || typeof extractor !== 'string') throw new Error('Record the actual extractor version with --extractor.');
  const record = { version: 1, scopes, extractor, inputs: fingerprint(root, scopes), preparedAt: new Date().toISOString() };
  writeJson(join(root, '.brain/graph-build.json'), record);
  return { state: 'prepared', ...record };
}
export function recordGraph(root) {
  const prep = readJson(join(root, '.brain/graph-build.json'));
  if (!prep) throw new Error('Run graph prepare before starting the graph build.');
  if (fingerprint(root, prep.scopes).hash !== prep.inputs.hash) throw new Error('Graph inputs changed during the build. Rebuild before recording it.');
  const graph = join(root, 'graphify-out/graph.json');
  if (!existsSync(graph)) throw new Error('The graph build produced no graph.json.');
  const record = { ...prep, graphHash: hash(readFileSync(graph)), recordedAt: new Date().toISOString() };
  writeJson(join(root, 'graphify-out/brain-inputs.json'), record);
  return { state: 'recorded', ...record };
}
export function graphStatus(root, extractor) {
  try {
    const record = readJson(join(root, 'graphify-out/brain-inputs.json'));
    if (!record) return { state: 'unknown', reason: 'No input fingerprint recorded; use committed-structure freshness only.' };
    if (record.version !== 1 || !record.inputs?.hash) return { state: 'unknown', reason: 'Unsupported fingerprint record.' };
    if (extractor && record.extractor !== extractor) return { state: 'stale', reason: 'Extractor version changed.' };
    const graph = join(root, 'graphify-out/graph.json');
    if (!existsSync(graph) || hash(readFileSync(graph)) !== record.graphHash) return { state: 'stale', reason: 'Graph output changed since its inputs were recorded.' };
    if (fingerprint(root, record.scopes).hash !== record.inputs.hash) return { state: 'stale', reason: 'Source files or graph scope configuration changed, including uncommitted changes.' };
    return { state: 'fresh', scopes: record.scopes, extractor: record.extractor, files: record.inputs.files };
  } catch (error) { return { state: 'unknown', reason: error.message }; }
}
