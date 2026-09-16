/**
 * Swift 源码结构自检（Node 运行，零依赖）
 *
 * 为什么需要它：我在 Windows 上无法编译 Swift/iOS，
 * 手工改了多处代码之后，"括号是否配平 / 有没有重复声明 / 有没有留占位符"
 * 是唯一能在本机验证的东西。这几项恰好是编辑事故的高发区。
 *
 * 检查项：
 *   1. 每个文件的 {} / () / [] 配平（跳过行注释、块注释、字符串字面量与字符串插值）
 *   2. 全仓顶层类型声明是否有重名（Swift 同名类型会编译失败）
 *   3. 残留占位符（TODO / FIXME / 待补充 / ...）
 *   4. 引用了声明中不存在的项目类型（只查已知的"未来阶段"类型名清单，避免误报）
 *
 * 用法： node tools/check_swift.js <源码根目录> [报告输出路径]
 */

const fs = require('fs');
const path = require('path');

const root = process.argv[2] || 'LumenEdit';
const reportPath = process.argv[3] || null;

const lines = [];
const rawLog = console.log.bind(console);
console.log = (...a) => { lines.push(a.join(' ')); rawLog(...a); };
const flush = () => { if (reportPath) fs.writeFileSync(path.resolve(reportPath), lines.join('\n') + '\n', 'utf8'); };

let failed = 0;
const ok = m => console.log('  OK   ' + m);
const bad = m => { failed++; console.log('  FAIL ' + m); };

/** 递归收集 .swift */
function walk(dir, out = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(full, out);
    else if (entry.name.endsWith('.swift')) out.push(full);
  }
  return out;
}

const files = walk(path.resolve(root)).sort();
console.log('Swift 文件 ' + files.length + ' 个，根目录：' + root + '\n');

/* ---------- 1. 括号配平 ---------- */
console.log('[1] 括号配平');
let balanceBad = 0;

for (const file of files) {
  const src = fs.readFileSync(file, 'utf8');
  const counters = { '{': 0, '(': 0, '[': 0 };
  const closers = { '}': '{', ')': '(', ']': '[' };

  let i = 0;
  let inLineComment = false;
  let inBlockComment = false;
  let inString = false;
  let inMultilineString = false;
  // 字符串内插值 \( ... ) 里会有真实的括号，需要按嵌套深度跟踪
  let interpolationDepth = 0;

  while (i < src.length) {
    const c = src[i];
    const next = src[i + 1];

    if (inLineComment) {
      if (c === '\n') inLineComment = false;
      i++; continue;
    }
    if (inBlockComment) {
      if (c === '*' && next === '/') { inBlockComment = false; i += 2; continue; }
      i++; continue;
    }
    if (inMultilineString) {
      if (c === '"' && src.substr(i, 3) === '"""') { inMultilineString = false; i += 3; continue; }
      i++; continue;
    }
    if (inString) {
      if (c === '\\' && next === '(') { interpolationDepth++; i += 2; continue; }
      if (c === ')' && interpolationDepth > 0) { interpolationDepth--; i++; continue; }
      if (c === '"' && interpolationDepth === 0) { inString = false; i++; continue; }
      i++; continue;
    }

    // 不在字符串/注释里
    if (c === '/' && next === '/') { inLineComment = true; i += 2; continue; }
    if (c === '/' && next === '*') { inBlockComment = true; i += 2; continue; }
    if (src.substr(i, 3) === '"""') { inMultilineString = true; i += 3; continue; }
    if (c === '"') { inString = true; i++; continue; }

    if (c in counters) counters[c]++;
    else if (c in closers) counters[closers[c]]--;

    i++;
  }

  const problems = [];
  for (const k of ['{', '(', '[']) {
    if (counters[k] !== 0) problems.push(`${k}${k === '{' ? '}' : k === '(' ? ')' : ']'} 差 ${counters[k]}`);
  }
  if (problems.length) {
    balanceBad++;
    bad(path.relative(root, file) + ' → ' + problems.join('，'));
  }
}
if (balanceBad === 0) ok('全部 ' + files.length + ' 个文件括号配平');

/* ---------- 2. 顶层类型重名 ---------- */
console.log('\n[2] 顶层类型声明重名');
const declared = new Map();
const declRe = /^(?:@[\w()]+\s+)*(?:public |internal |private |fileprivate |final |open )*(class|struct|enum|protocol|actor)\s+([A-Za-z_][\w]*)/gm;

for (const file of files) {
  const src = fs.readFileSync(file, 'utf8');
  let m;
  while ((m = declRe.exec(src))) {
    const name = m[2];
    if (!declared.has(name)) declared.set(name, []);
    declared.get(name).push(path.relative(root, file));
  }
}
const dupes = [...declared.entries()].filter(([, fs_]) => fs_.length > 1);
if (dupes.length) {
  dupes.forEach(([name, where]) => bad(`类型 ${name} 重复声明于：${where.join(' / ')}`));
} else {
  ok(`共 ${declared.size} 个类型，无重名`);
}

/* ---------- 3. 占位符 ---------- */
console.log('\n[3] 残留占位符');
const placeholderRe = /TODO|FIXME|XXX\b|待补充|自行补充|not implemented yet/;
let ph = 0;
for (const file of files) {
  const src = fs.readFileSync(file, 'utf8');
  src.split('\n').forEach((line, idx) => {
    if (placeholderRe.test(line)) {
      ph++;
      bad(path.relative(root, file) + ':' + (idx + 1) + ' → ' + line.trim());
    }
  });
}
if (ph === 0) ok('无 TODO / 占位符');

/* ---------- 4. 引用未来阶段的类型 ---------- */
console.log('\n[4] 是否引用了尚未创建的类型');
const FUTURE = [
  'MovieCaptureService', 'RecordingIndicator', 'SessionControlsCoordinator',
  'PhotoExporter', 'LivePhotoExporter', 'VideoExporter', 'ImageLoader',
  'LibraryView', 'LibraryViewModel', 'ImportCoordinator', 'AssetResourceResolver',
  'EditRecipe', 'AdjustmentPipeline', 'AdjustmentKind', 'FilterCatalog', 'FilterRenderer',
  'EditorView', 'EditorViewModel', 'PreviewCanvas', 'AdjustmentPanel', 'FilterStrip',
  'LivePhotoEditService', 'LivePhotoPreviewView', 'VideoEditService',
  'CIFilterVideoCompositor', 'VideoEditorView'
];
let futureRefs = 0;
for (const file of files) {
  const src = fs.readFileSync(file, 'utf8');
  src.split('\n').forEach((line, idx) => {
    const trimmed = line.trim();
    // 注释里提到不算引用
    if (trimmed.startsWith('//') || trimmed.startsWith('///') || trimmed.startsWith('*')) return;
    for (const name of FUTURE) {
      if (new RegExp('\\b' + name + '\\b').test(line)) {
        futureRefs++;
        bad(path.relative(root, file) + ':' + (idx + 1) + ' 引用了未创建的类型 ' + name);
      }
    }
  });
}
if (futureRefs === 0) ok('未引用任何未来阶段的类型，当前阶段可以独立编译');

/* ---------- 结论 ---------- */
console.log('\n' + (failed === 0 ? '全部通过：结构自检无问题' : '有 ' + failed + ' 项未通过，需要修'));
flush();
process.exit(failed === 0 ? 0 : 1);
