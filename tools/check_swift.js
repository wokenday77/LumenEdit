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
 *   5. 顶栏模式条宽度预算（2026-09-17 新增）
 *      —— 按 Theme.swift 的令牌复算条宽，对 402/393/390/375 四种屏宽验余量。
 *      存在的意义：ModeSelector 里 ViewThatFits 的降档是**静默**的，
 *      装不下只会悄悄换小字号，编译器和真机截图都看不出来。
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
// ⚠️ 这个清单要随阶段推进维护：某个类型一旦真的创建了，就必须从这里移除，
// 否则自检会把「正常引用自己刚新建的类型」误报成「引用了未创建的类型」。
// 2026-09-16：MovieCaptureService 已在 P1b-2 创建（Camera/Output/MovieCaptureService.swift），
// 故从清单移除。
const FUTURE = [
  'RecordingIndicator', 'SessionControlsCoordinator',
  'PhotoExporter', 'LivePhotoExporter', 'VideoExporter', 'ImageLoader',
  'LibraryView', 'LibraryViewModel', 'ImportCoordinator', 'AssetResourceResolver',
  'EditRecipe', 'AdjustmentPipeline', 'AdjustmentKind', 'FilterRenderer',
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

/* ---------- 5. 顶栏模式条宽度预算 ---------- */
// 为什么要这条：模式条的宽度是**算出来的**，而 ModeSelector 里 ViewThatFits 的降档是**静默**的
// —— 装不下就悄悄换小字号，不报错、不影响编译。加第 5 个模式、接 Dynamic Type、
// 文案变长、字号被调大，都会悄悄逼近临界。
// 这里按 Theme.swift 的令牌把宽度复算一遍：超预算就 FAIL，让它在 CI 里就暴露，
// 而不是等到真机上"字变小了但没人知道"。
console.log('\n[5] 顶栏模式条宽度预算');

const themeFile = files.find(f => f.endsWith(path.join('DesignSystem', 'Theme.swift')));
const modeSelFile = files.find(f => f.endsWith(path.join('Components', 'ModeSelector.swift')));
const topBarFile = files.find(f => f.endsWith(path.join('Camera', 'UI', 'TopBarView.swift')));

if (!themeFile || !modeSelFile || !topBarFile) {
  bad('找不到 Theme.swift / ModeSelector.swift / TopBarView.swift（文件被改名或挪位置了？）');
} else {
  const themeSrc = fs.readFileSync(themeFile, 'utf8');
  const modeSelSrc = fs.readFileSync(modeSelFile, 'utf8');
  const topBarSrc = fs.readFileSync(topBarFile, 'utf8');

  /** 从 Theme.swift 读一个 `name: CGFloat = 数字` 形式的令牌 */
  const readCGFloat = (src, name) => {
    const m = new RegExp('\\b' + name + '\\s*:\\s*CGFloat\\s*=\\s*([0-9.]+)').exec(src);
    return m ? parseFloat(m[1]) : null;
  };

  const T = {
    regularFont: readCGFloat(themeSrc, 'modeTitleSize'),
    compactFont: readCGFloat(themeSrc, 'modeTitleCompactSize'),
    regularSpacing: readCGFloat(themeSrc, 'modeSelectorSpacing'),
    compactSpacing: readCGFloat(themeSrc, 'modeSelectorCompactSpacing'),
    minHitWidth: readCGFloat(themeSrc, 'modeTabMinHitWidth'),
    glyph: readCGFloat(themeSrc, 'modeSelectorGlyphSize'),
    sideWidth: readCGFloat(themeSrc, 'topBarSideWidth'),
    rowSpacing: readCGFloat(themeSrc, 'topBarMainRowSpacing'),
    sidePadding: readCGFloat(themeSrc, 'md')   // Theme.Spacing.md → 顶栏内容左右内边距
  };

  const missing = Object.keys(T).filter(k => T[k] === null);
  if (missing.length) {
    bad('读不到令牌：' + missing.join(' / ') + '（改名了？自检需要同步）');
  } else {
    // 宽度模型（标定过程见 docs/08 三.2）：
    //   中文字宽 ≈ 1.0 × 字号；「Log 」≈ 1.97 × 字号（SF Rounded semibold）
    //   每档单元宽 = max(内容宽 + 档间距, 命中下限)
    const LATIN_LOG = 1.97;
    const cell = (content, spacing) => Math.max(T.minHitWidth, content + spacing);
    const barWidth = (font, spacing) =>
      cell(2 * font, spacing) +            // 照片
      cell(T.glyph, spacing) +             // 实况（图标）
      cell(LATIN_LOG * font + 2 * font, spacing) +   // Log 实况
      cell(2 * font, spacing);             // 视频

    const regular = barWidth(T.regularFont, T.regularSpacing);
    const compact = barWidth(T.compactFont, T.compactSpacing);

    // 中段可用宽 = 屏宽 − 两侧内边距 − 两侧块宽 − 两侧行间距
    const middle = screen => screen - 2 * T.sidePadding - 2 * T.sideWidth - 2 * T.rowSpacing;

    console.log(
      '  模式条宽（' + T.regularFont + 'pt 版）' + regular.toFixed(1) + 'pt'
      + ' · （' + T.compactFont + 'pt 版）' + compact.toFixed(1) + 'pt'
      + ' · 命中下限 ' + T.minHitWidth + 'pt'
    );

    // 主行 spacing 必须是 0 —— 非 0 会直接从中段里扣掉两倍它（2026-09-17 真实踩过：
    // 给了 8，中段从 224 掉到 208，393/390 机型当场溢出）
    if (T.rowSpacing !== 0) {
      bad('顶栏主行 spacing = ' + T.rowSpacing + '（必须为 0，否则中段少掉 ' + (2 * T.rowSpacing) + 'pt）');
    } else {
      ok('顶栏主行 spacing = 0（中段可用宽度不被行间距侵蚀）');
    }

    // 各机型：全部要求"装得下且留余量"。
    // 375（SE / mini）用 12pt 版、余 5.4pt（≈2.7%，覆盖宽度模型 ≈1% 的误差）。
    //
    // ⚠️ 这里曾经给 375 留过 −6pt 的容差（允许小幅溢出、靠两侧块空白吸收）——
    // 那是基于一个**算错的**中段宽度（181pt，错把主行 spacing 算进去了）。
    // 真实中段是 197pt，紧凑版 191.6pt 本来就够，容差已收紧为 0：
    // 一旦将来真的装不下，宁可自检报错，也不要靠"溢出被吸收"这种隐含假设。
    const devices = [
      { name: 'iPhone 16 Pro（402pt）', screen: 402, font: T.regularFont, bar: regular, slack: 8 },
      { name: 'iPhone 16 / 15（393pt）', screen: 393, font: T.regularFont, bar: regular, slack: 8 },
      { name: 'iPhone 14（390pt）', screen: 390, font: T.regularFont, bar: regular, slack: 8 },
      { name: 'iPhone SE / mini（375pt）', screen: 375, font: T.compactFont, bar: compact, slack: 0 }
    ];

    for (const d of devices) {
      const m = middle(d.screen);
      const left = m - d.bar;
      const label = d.name + ' 中段 ' + m.toFixed(1) + 'pt，实际' + d.font + 'pt 版用 '
        + d.bar.toFixed(1) + 'pt，余 ' + left.toFixed(1) + 'pt';
      if (left < d.slack) {
        bad(label + '（需 ≥ ' + d.slack + 'pt）');
      } else {
        ok(label);
      }
    }

    // 快门：录制态内芯是**圆角方块**，它的四个角比圆"远"得多 ——
    // 半对角线必须留在环内沿里面（留 2pt 呼吸），否则红方块的角会插进白色环带
    // （2026-09-17 真机 bug：内芯与拍照态共用 46pt，四角到中心 29.7 > 环内沿 28.25）。
    // 环用 .stroke（SwiftUI 是**居中**描边）→ 环内沿半径 = (直径 − 环宽) / 2
    const D = readCGFloat(themeSrc, 'shutterDiameter');
    const ring = readCGFloat(themeSrc, 'shutterRingWidth');
    const recCore = readCGFloat(themeSrc, 'shutterRecordingCoreSize');
    const photoCore = readCGFloat(themeSrc, 'shutterCoreSize');
    if (D === null || ring === null || recCore === null || photoCore === null) {
      bad('读不到快门令牌（shutterDiameter / shutterRingWidth / shutterRecordingCoreSize / shutterCoreSize）');
    } else {
      const ringInner = (D - ring) / 2;
      const recHalfDiagonal = recCore * Math.SQRT2 / 2;
      const photoHalf = photoCore / 2;
      const limit = ringInner - 2;

      const recLabel = '录制态内芯 ' + recCore + 'pt 半对角线 ' + recHalfDiagonal.toFixed(1)
        + 'pt vs 环内沿 ' + ringInner.toFixed(1) + 'pt（限 ' + limit.toFixed(1) + '）';
      if (recHalfDiagonal > limit) {
        bad(recLabel + ' —— 四角会插进白色环带');
      } else {
        ok(recLabel);
      }

      // 拍照态是圆，用半径比即可（同时确认它没有大到顶住环）
      if (photoHalf > limit) {
        bad('拍照态内芯半径 ' + photoHalf.toFixed(1) + 'pt 超过环内沿 −2（' + limit.toFixed(1) + 'pt）');
      } else {
        ok('拍照态内芯半径 ' + photoHalf.toFixed(1) + 'pt ≤ 环内沿 −2（' + limit.toFixed(1) + 'pt）');
      }
    }

    // 降档路径本身必须存在，否则窄屏会靠"压缩"而不是"降档"糊过去（静默）
    if (!/ViewThatFits/.test(modeSelSrc)
      || !/modeSelectorSpacing/.test(modeSelSrc)
      || !/modeSelectorCompactSpacing/.test(modeSelSrc)) {
      bad('ModeSelector 里的 ViewThatFits 降档路径不完整（两套度量必须都在）');
    } else {
      ok('ModeSelector 保留了 ViewThatFits 降档路径（窄屏不会静默压缩）');
    }

    // 底部图标行：七项等宽，命中单元要 ≥ 44pt。
    // 2026-09-17 的教训：布局账按原型 370pt 算出 51.1pt/格，真机 402pt 实际是 55.7pt
    // —— **同一行布局要在每种真机屏宽下各算一遍**，不能只记 CSS 稿的那一行。
    const xs = readCGFloat(themeSrc, 'xs');
    if (xs === null) {
      bad('读不到 Theme.Spacing.xs（顶栏/图标行左右内边距）');
    } else {
      const TOOL_CELL_COUNT = 7;   // ToolIconRow 的七项（前置/对焦/白平衡/感光/快门速度/曝光补偿/设置）
      for (const d of devices) {
        const cell = (d.screen - 2 * xs) / TOOL_CELL_COUNT;
        const label = d.name + ' 图标行单元格 ' + cell.toFixed(1) + 'pt（7 等分）';
        if (cell < T.minHitWidth) {
          bad(label + '（低于 HIG ' + T.minHitWidth + 'pt，需要减项或改布局）');
        } else {
          ok(label);
        }
      }
    }
  }
}

/* ---------- 6. 状态引用完整性 ---------- */
// 为什么要这条：2-5b 的一次编辑本意是**新增** `isZoomOn`，却把 `focal` 那一行**替换**掉了，
// 于是 `focalTapped` 与 `CameraView` 里的绑定全部失效 —— 括号配平、占位符检查全都看不出来，
// 只能等 CI 编译报错（整整一轮 Mac 往返）。这类"删了状态但引用还在"的回归，
// 用一条"引用必须在对应状态类里存在"的静态检查就能在 push 前拦住。
console.log('\n[6] 状态引用完整性');

const stateOwners = {
  viewModel: 'CameraViewModel.swift',
  env: 'AppEnvironment.swift'
};

for (const [prefix, ownerName] of Object.entries(stateOwners)) {
  const owner = files.find(f => path.basename(f) === ownerName);
  if (!owner) {
    bad('找不到状态类 ' + ownerName + '（改名了？自检需要同步）');
    continue;
  }
  const ownerSrc = fs.readFileSync(owner, 'utf8');
  const re = new RegExp('\\b' + prefix + '\\.(\\w+)', 'g');
  const missing = new Map();

  for (const file of files) {
    const src = fs.readFileSync(file, 'utf8');
    let m;
    while ((m = re.exec(src))) {
      const member = m[1];
      if (!new RegExp('\\b' + member + '\\b').test(ownerSrc)) {
        if (!missing.has(member)) missing.set(member, new Set());
        missing.get(member).add(path.relative(root, file));
      }
    }
  }

  if (missing.size) {
    for (const [member, where] of missing) {
      bad('引用了 ' + prefix + '.' + member + '，但 ' + ownerName + ' 里没有它（引用处：'
        + [...where].join(' / ') + '）');
    }
  } else {
    ok(prefix + '.* 的引用都能在 ' + ownerName + ' 里找到');
  }
}

/* ---------- 结论 ---------- */
console.log('\n' + (failed === 0 ? '全部通过：结构自检无问题' : '有 ' + failed + ' 项未通过，需要修'));
flush();
process.exit(failed === 0 ? 0 : 1);
