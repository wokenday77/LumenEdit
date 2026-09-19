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

/* ---------- 2b. 同一类型内重复成员声明 ---------- */
// 为什么加（2026-09-18 实际发生）：给 `TopBarView` 加 #11 参数时，又在下面声明了一次
// `let storageText`（上面已有同名字段）→ **编译失败**，而本地无法编译，一路 push 到 Mac
// 才由编译报错抓出来（Mac 侧 `156abd9` 代为修复）。
// 第 2 组只查"顶层类型重名"，查不到"类型内成员重复" —— 这个缺口必须补：
// **本地不能编译，静态检查就是唯一防线。**
//
// 判据与精度：
//   - 只查**属性**（`let` / `var`，含 `@Published`、`private(set)` 等修饰）——
//     属性重名是本次的真实问题，且误报率最低；
//   - `static` 与实例属性分开计（Swift 允许 `Type.x` 与 `instance.x` 共存）；
//   - 跨 `extension` 也算同一类型（Swift 同样不允许跨扩展重名）→ key 用"类型名"；
//   - 只检查**类型的直接子级**（按花括号深度判定）→ 函数/闭包内的局部变量不会被误报。
console.log('\n[2b] 同类型内重复成员声明');

let dupMembers = 0;
for (const file of files) {
  const lines = fs.readFileSync(file, 'utf8').split('\n');
  let depth = 0;
  let inBlockComment = false;
  const scopes = [];              // { name, memberDepth }
  const seen = new Map();         // `${类型名}|${static?}|${属性名}` → 行号

  for (let i = 0; i < lines.length; i++) {
    let line = lines[i];
    if (inBlockComment) {
      const end = line.indexOf('*/');
      if (end < 0) continue;
      line = line.slice(end + 2);
      inBlockComment = false;
    }
    const bc = line.indexOf('/*');
    if (bc >= 0) { inBlockComment = true; line = line.slice(0, bc); }
    const lc = line.indexOf('//');
    if (lc >= 0) line = line.slice(0, lc);
    const code = line.replace(/"(?:[^"\\]|\\.)*"/g, '""');   // 抹掉字符串字面量
    const trimmed = code.trim();

    // 类型开始 → 新作用域（成员深度 = 当前深度 + 1）
    const typeStart = /^(?:@\w+(?:\([^)]*\))?\s+)*(?:public\s+|internal\s+|private\s+|fileprivate\s+|final\s+|open\s+)*(struct|class|enum|actor|extension)\s+([A-Za-z_]\w*)/.exec(trimmed);
    if (typeStart) scopes.push({ name: typeStart[2], memberDepth: depth + 1 });

    // 属性声明（只在类型的直接子级）
    const scope = scopes.length ? scopes[scopes.length - 1] : null;
    if (scope && depth === scope.memberDepth) {
      const m = /^(?:@\w+(?:\([^)]*\))?\s+)*(?:public\s+|internal\s+|private\s+|fileprivate\s+|private\(set\)\s+)*(static\s+)?(?:final\s+)?(let|var)\s+([A-Za-z_]\w*)\s*[:=]/.exec(trimmed);
      if (m) {
        const key = scope.name + '|' + (m[1] ? 'static' : 'instance') + '|' + m[3];
        if (seen.has(key)) {
          dupMembers++;
          bad(path.relative(root, file) + ':' + (i + 1) + ' → ' + scope.name + ' 内重复声明 '
            + (m[1] ? 'static ' : '') + m[2] + ' ' + m[3]
            + '（首次在第 ' + seen.get(key) + ' 行）');
        } else {
          seen.set(key, i + 1);
        }
      }
    }

    // 花括号深度（含离开类型作用域时的弹出）
    for (const ch of code) {
      if (ch === '{') {
        depth++;
      } else if (ch === '}') {
        depth--;
        while (scopes.length && depth < scopes[scopes.length - 1].memberDepth) scopes.pop();
      }
    }
  }
}
if (dupMembers === 0) ok('无同类型成员重复声明（' + files.length + ' 个文件）');

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

    // 场景·风格条展开态：**内容深度必须 ≤ 行高 147**。
    // 原型第 5 轮就是在这里翻车的：折叠胶囊 + 两块内容叠在一起，溢出 39px 压到图标行，
    // 而且**自检只校验了行高、没校验内容深度**，所以一直没报 —— 这条就是冲着那个来的。
    const ss = {
      expanded: readCGFloat(themeSrc, 'sceneStyleExpandedHeight'),
      title: readCGFloat(themeSrc, 'ssBlockTitleHeight'),
      topPad: readCGFloat(themeSrc, 'ssBlockTopPadding'),
      chip: readCGFloat(themeSrc, 'sceneChipHeight'),
      thumb: readCGFloat(themeSrc, 'styleCardThumbHeight'),
      cardSpacing: readCGFloat(themeSrc, 'styleCardSpacing'),
      nameHeight: readCGFloat(themeSrc, 'styleNameHeight'),
      badge: readCGFloat(themeSrc, 'styleBadgeHeight')
    };
    const ssMissing = Object.keys(ss).filter(k => ss[k] === null);
    if (ssMissing.length) {
      bad('读不到场景·风格令牌：' + ssMissing.join(' / '));
    } else {
      const BLOCK_BORDER = 0.5;          // 块顶分隔线（SceneStyleStrip 里的字面量）
      const styleCard = ss.thumb + ss.cardSpacing + ss.nameHeight + ss.cardSpacing + ss.badge;
      const depth = 2 * (BLOCK_BORDER + ss.topPad + ss.title) + ss.chip + styleCard;
      const label = '场景·风格展开态内容深度 ' + depth.toFixed(1) + 'pt vs 行高 '
        + ss.expanded.toFixed(1) + 'pt（风格卡 ' + styleCard.toFixed(1) + 'pt）';
      // 名字行高已钉死，深度是确定值 —— 允许恰好贴合，超出即 FAIL
      if (depth > ss.expanded + 0.01) {
        bad(label + ' —— 内容会溢出压到下面的行');
      } else {
        ok(label + '，余 ' + (ss.expanded - depth).toFixed(1) + 'pt');
      }
    }
  }
}

/* ---------- 工具：按函数体提取 ---------- */
// 为什么要有它：断言"某函数的函数体里必须出现 X"时，用固定字符窗口（如 {0,400}）
// 会在函数被加长后**静默失效**（2026-09-18 实际发生：toggleSceneStyle 加了连带检测后
// 长度翻倍，互斥断言直接误报"互斥不全"）。改成提取到同级闭合花括号，长度无关。
/** 取一个 4 空格缩进的方法体：从 `func 名` 到同级的 `    }`；找不到返回 null */
function methodBodyOf(src, fnName) {
  const m = new RegExp('func ' + fnName + '\\b[\\s\\S]*?\\n    \\}').exec(src);
  return m ? m[0] : null;
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

/* ---------- 7. 滤镜条（#7，2026-09-18 新增） ---------- */
// 为什么要有这一组：滤镜条与场景·风格条一样是"高度账 + 互斥规则"两个高危区 ——
// 内容深度超了会压到下面的行（原型第 5 轮翻过车）、互斥只做单方向会出现
// "两个扩展浮层同时展开"把净可见压破 50%。这类问题编译器看不见，只能静态查。
console.log('\n[7] 滤镜条');

const filterStripFile = files.find(f => f.endsWith(path.join('Camera', 'UI', 'FilterStripView.swift')));
const vmFile = files.find(f => path.basename(f) === 'CameraViewModel.swift');
const camViewFile = files.find(f => path.basename(f) === 'CameraView.swift');
const thumbFile = files.find(f => f.endsWith(path.join('DesignSystem', 'Components', 'StyleThumbnailView.swift')));
const themeFile2 = files.find(f => f.endsWith(path.join('DesignSystem', 'Theme.swift')));

if (!filterStripFile || !vmFile || !camViewFile || !thumbFile || !themeFile2) {
  bad('找不到 FilterStripView / CameraViewModel / CameraView / StyleThumbnailView / Theme（文件被改名或挪位置了？）');
} else {
  const stripSrc = fs.readFileSync(filterStripFile, 'utf8');
  const vmSrc = fs.readFileSync(vmFile, 'utf8');
  const viewSrc = fs.readFileSync(camViewFile, 'utf8');
  const thumbSrc = fs.readFileSync(thumbFile, 'utf8');
  const themeSrc2 = fs.readFileSync(themeFile2, 'utf8');

  // ① 展开态内容深度 ≤ 行高 144（与第 5 组场景·风格那条同一条理由：
  //    只校验行高拦不住内容溢出 —— 原型第 5 轮就是"行高够、内容溢出 39px"）
  const readTok = name => {
    const m = new RegExp('\\b' + name + '\\s*:\\s*CGFloat\\s*=\\s*([0-9.]+)').exec(themeSrc2);
    return m ? parseFloat(m[1]) : null;
  };
  const ft = {
    height: readTok('filterStripExpandedHeight'),
    topPad: readTok('filterStripTopPadding'),
    title: readTok('ssBlockTitleHeight'),
    gap: readTok('filterStripCardTopGap'),
    card: readTok('filterCardSide'),
    inner: readTok('filterCardInnerSpacing'),
    name: readTok('filterNameHeight')
  };
  const ftMissing = Object.keys(ft).filter(k => ft[k] === null);
  if (ftMissing.length) {
    bad('读不到滤镜条令牌：' + ftMissing.join(' / ') + '（改名了？自检需要同步）');
  } else {
    // 深度 = 顶内边距 7 + 标题 14 + 标题↔卡间距 9 + 卡 84 + 卡内距 4 + 名字 11
    const depth = ft.topPad + ft.title + ft.gap + ft.card + ft.inner + ft.name;
    const label = '滤镜条展开态内容深度 ' + depth.toFixed(1) + 'pt vs 行高 ' + ft.height.toFixed(1) + 'pt';
    if (depth > ft.height + 0.01) {
      bad(label + ' —— 内容会溢出压到下面的行');
    } else {
      ok(label + '，余 ' + (ft.height - depth).toFixed(1) + 'pt');
    }
    // 高度本身不许松：144 是"净可见 ≥ 50%"卡出来的上限（原型注释），放大它前先重算布局账
    if (ft.height > 150) {
      bad('滤镜条展开高度 ' + ft.height + 'pt 超过 150 —— 原型实测 150 时净可见只剩 49.9%，破 50% 底线');
    } else {
      ok('滤镜条展开高度 ' + ft.height + 'pt ≤ 150（净可见底线守住了）');
    }
  }

  // ② 互斥两方向都要在（单方向会出现两个扩展浮层同时展开）
  const toggleSSBody = methodBodyOf(vmSrc, 'toggleSceneStyle');
  const mutexOK =
    // 展开场景·风格 → 收起滤镜条（toggleSceneStyle，原型 setSS）
    !!toggleSSBody && /isFilterStripExpanded\s*=\s*false/.test(toggleSSBody)
    // 上划呼出滤镜条 → 收起场景·风格（swiped(up:)，原型 setFilter(true)）
    && /isFilterStripExpanded\s*=\s*true/.test(vmSrc)
    && /isSceneStyleExpanded\s*=\s*false/.test(vmSrc);
  if (mutexOK) {
    ok('浮层互斥两方向齐全（toggleSceneStyle ⇄ swiped(up:)）');
  } else {
    bad('浮层互斥不全：展开一个浮层时必须收起另一个（对照原型 setSS / setFilter）');
  }

  // ③ CameraView 接线：滤镜条渲染 + 焦段条互斥都要引用同一份展开状态
  const viewRefs = (viewSrc.match(/isFilterStripExpanded|isFilterStripShown/g) || []).length;
  if (!/FilterStripView\(/.test(viewSrc)) {
    bad('CameraView 没有渲染 FilterStripView');
  } else if (viewRefs < 2) {
    bad('CameraView 对滤镜条状态的引用只有 ' + viewRefs + ' 处（至少要：渲染 + 焦段条互斥）');
  } else {
    ok('CameraView 已接线滤镜条渲染与焦段条互斥（' + viewRefs + ' 处引用）');
  }

  // ④ 卡片数据驱动 + 缩略图同源：卡来自 FilterCatalog.all，
  //    swatches hex 解析复用 StyleThumbnailView.color(from:)（全工程一份，不维护第二份）
  if (!/FilterCatalog\.all/.test(stripSrc)) {
    bad('FilterStripView 没有从 FilterCatalog.all 取数（滤镜数据必须单一真源）');
  } else if (!/StyleThumbnailView\.color\(from:/.test(stripSrc)) {
    bad('FilterStripView 没有复用 StyleThumbnailView.color(from:)（hex 解析不许抄第二份）');
  } else if (/private\s+static\s+func\s+color\(from/.test(thumbSrc)) {
    bad('StyleThumbnailView.color(from:) 又被改回 private 了（滤镜卡要复用它）');
  } else {
    ok('滤镜卡数据驱动 + hex 解析同源（FilterCatalog.all + StyleThumbnailView.color(from:)）');
  }

  // ⑤ 手势几何参数必须成组存在（原型 bindSwipe 的口径：24 起手 / 34 位移 / 0.8s / 55%）
  const gesture = ['swipeActivationDistance', 'swipeMinTravel', 'swipeMaxDuration', 'swipeStartRegionRatio'];
  const gestureMissing = gesture.filter(g => !new RegExp('\\b' + g + '\\b').test(viewSrc));
  if (gestureMissing.length) {
    bad('上划手势参数缺失：' + gestureMissing.join(' / '));
  } else if (!/simultaneousGesture/.test(viewSrc)) {
    bad('取景器手势没用 simultaneousGesture（会吞掉 UIKit 的点按对焦）');
  } else {
    ok('上划/下划手势参数齐全，且与点按对焦并存（simultaneousGesture）');
  }

  // ⑥ 底栏到安全区的内边距令牌（Mac 侧 0609fa9 引入，注释承诺"自检第 7 组会校验"）：
  //    它必须恒等于两层各 10pt 之和 —— 任何"从底部往上量"的浮层都吃这一整份，
  //    改内边距时漏改令牌，卡片底边就会多出/少掉一层。
  const stackPad = readTok('bottomStackBottomPadding');
  const sm = readTok('sm');
  if (stackPad === null || sm === null) {
    bad('读不到 bottomStackBottomPadding / Theme.Spacing.sm（改名了？自检需要同步）');
  } else if (Math.abs(stackPad - 2 * sm) > 0.01) {
    bad('bottomStackBottomPadding = ' + stackPad + 'pt ≠ 2 × Spacing.sm（' + (2 * sm) + 'pt）—— 两层内边距的账对不上');
  } else {
    ok('bottomStackBottomPadding = ' + stackPad + 'pt = 2 × Spacing.sm（两层内边距账目一致）');
  }
}


/* ---------- 8. 底部手势与参数排（2026-09-18 真机三问题后补） ---------- */
// 为什么要这一组：底部这一片同时住着「上滑/下划手势」「常驻参数排」「EV 滑条」，
// 三者互相吃触摸 —— 出了问题全都表现为"手势不灵 / 被干扰 / 关不掉"，而根因是几何账
// （可用起手带只剩 6pt），编译器一点提示都没有。这里把口径钉住：
//   a) 手势阈值只能**更宽松**，不许被谁改回原型那套严口径；
//   b) 参数排必须默认收起，且图标行「曝光补偿」必须是它的开关；
//   c) 互斥（含参数排）必须在 collapseOverlays() 一处收口；
//   d) EV 滑条必须有方向闸门（竖向落手不许改值）。
console.log('\n[8] 底部手势与参数排');

if (!camViewFile || !vmFile) {
  bad('找不到 CameraView.swift / CameraViewModel.swift（改名了？自检需要同步）');
} else {
  const viewSrc8 = fs.readFileSync(camViewFile, 'utf8');
  const vmSrc8 = fs.readFileSync(vmFile, 'utf8');
  const sliderFile = files.find(f => path.basename(f) === 'ParameterSlider.swift');

  // a) 手势阈值：真机反馈"要很用力 + 特定位置"后放宽过一次，不许静默改回
  const numOf = (src, name) => {
    const m = new RegExp('\\b' + name + '\\s*:\\s*(?:CGFloat|TimeInterval)\\s*=\\s*([0-9.]+)').exec(src);
    return m ? parseFloat(m[1]) : null;
  };
  const g = {
    activation: numOf(viewSrc8, 'swipeActivationDistance'),
    travel: numOf(viewSrc8, 'swipeMinTravel'),
    duration: numOf(viewSrc8, 'swipeMaxDuration'),
    startRatio: numOf(viewSrc8, 'swipeStartRegionRatio'),
    slack: numOf(viewSrc8, 'swipeHorizontalSlack')
  };
  const gMissing = Object.keys(g).filter(k => g[k] === null);
  if (gMissing.length) {
    bad('读不到手势参数：' + gMissing.join(' / '));
  } else {
    // ⚠️ 改成**区间守卫**（2026-09-18 第三轮）：早先只守"不许太严"（单向上限），
    // 结果是放宽过头 → 真机反馈"太敏感"。两端都要守：太严会"要很用力"，太松会误触。
    let badG = false;
    const ranges = [
      ['swipeActivationDistance', g.activation, 8, 16, '起手门槛'],
      // 位移阈值：34 偏硬 → 16 过敏 → **28 定稿**（Mac 复验实测 20pt≈4.4mm 仍在敏感侧，
      // 心理预期 5~6mm）。区间给 18~32 覆盖"能用的两端"，超出就往某个极端跑了。
      ['swipeMinTravel', g.travel, 18, 32, '位移阈值'],
      ['swipeStartRegionRatio', g.startRatio, 0.1, 0.35, '起点线']
    ];
    for (const [name, value, lo, hi, why] of ranges) {
      if (value < lo) {
        bad(name + ' = ' + value + ' 低于 ' + lo + '（' + why + '太严 → "要很用力"）');
        badG = true;
      } else if (value > hi) {
        bad(name + ' = ' + value + ' 超过 ' + hi + '（' + why + '太松 → 误触）');
        badG = true;
      }
    }
    // 时长是**宽容度**参数不是敏感度参数：它只会被调大，调小等于回到"滑快才认"
    if (g.duration < 1.0) {
      bad('swipeMaxDuration = ' + g.duration + 's 小于 1.0s（慢滑会被拒，等于回到"要很用力"）');
      badG = true;
    }
    if (g.slack < 1.0) {
      bad('swipeHorizontalSlack = ' + g.slack + ' 小于 1.0（斜着上滑会被误判为横滑）');
      badG = true;
    }
    // 方向锁死区：太小则主轴判定含糊，太大则起手要滑很远才定性
    const axisZone = numOf(viewSrc8, 'swipeAxisDeadZone');
    if (axisZone === null) {
      bad('读不到 swipeAxisDeadZone（方向锁起手死区）');
      badG = true;
    } else if (axisZone < 6 || axisZone > 14) {
      bad('swipeAxisDeadZone = ' + axisZone + 'pt 不在 6~14 之间（太小判定含糊 / 太大起手要滑很远才定性）');
      badG = true;
    }
    if (!badG) {
      ok('手势口径在合理区间（起手 ' + g.activation + ' / 位移 ' + g.travel + 'pt / 时长 '
        + g.duration + 's / 起点 ' + g.startRatio + ' / 横向裕度 ' + g.slack
        + ' / 方向锁死区 ' + axisZone + 'pt）');
    }
  }

  // b) 参数排：默认收起 + 图标行「曝光补偿」是它的开关
  if (!/isExposurePanelExpanded/.test(vmSrc8)) {
    bad('CameraViewModel 里没有 isExposurePanelExpanded —— 参数排又变回常驻了？');
  } else if (!/isExposurePanelExpanded\s*(?::\s*[^=\n]+)?=\s*false/.test(vmSrc8)) {
    bad('isExposurePanelExpanded 没有显式默认 false（参数排应默认收起）');
  // ⚠️ 这一条原来用**字符窗口**匹配（`func exposureCompensationTapped[\s\S]{0,400}?...toggle()`），
  //    2026-09-19 B2a 被自己的注释挤爆过一次：在函数开头加了一段守卫说明（EV 与手动档互斥），
  //    窗口就不够了 → **报了个假的 FAIL**。
  //    改成**按函数体匹配**（`methodBodyOf`）—— 不再数窗口，加注释/加分支都不会失效。
  } else if (!/isExposurePanelExpanded\.toggle\(\)/.test(
    methodBodyOf(vmSrc8, 'exposureCompensationTapped') || ''
  )) {
    bad('图标行「曝光补偿」没有走 toggle —— 那参数排就没有收起入口（用户找不到关闭方式）');
  } else if (!/isExposurePanelShown/.test(viewSrc8)) {
    bad('CameraView 没用 isExposurePanelShown 门控参数排（放大态/收起态会漏渲染）');
  } else {
    ok('参数排默认收起，且由图标行「曝光补偿」toggle（有收起入口）');
  }

  // c) 互斥收口：collapseOverlays() 必须同时管三个（新增浮层必须加进来）
  const collapseBody = methodBodyOf(vmSrc8, 'collapseOverlays');
  if (!collapseBody) {
    bad('找不到 collapseOverlays()');
  } else {
    const body = collapseBody;
    const needed = ['isFilterStripExpanded', 'isSceneStyleExpanded', 'isExposurePanelExpanded'];
    const miss = needed.filter(n => !new RegExp(n + '\\s*=\\s*false').test(body));
    if (miss.length) {
      bad('collapseOverlays() 没收起：' + miss.join(' / ') + '（下划会收不干净）');
    } else {
      ok('collapseOverlays() 一次收起全部扩展浮层（滤镜条 / 场景·风格 / 参数排）');
    }
  }
  // 展开另外两个浮层时也必须收参数排（互斥三方向）
  const toggleSS8 = methodBodyOf(vmSrc8, 'toggleSceneStyle');
  const swiped8 = methodBodyOf(vmSrc8, 'swiped');
  const mutex3 = !!toggleSS8 && /isExposurePanelExpanded\s*=\s*false/.test(toggleSS8)
    && !!swiped8 && /isExposurePanelExpanded\s*=\s*false/.test(swiped8);
  if (mutex3) {
    ok('展开场景·风格 / 呼出浮层时都会收起参数排（互斥三方向齐全）');
  } else {
    bad('互斥不全：展开场景·风格或呼出浮层时没有收起参数排');
  }

  // d) EV 滑条的方向闸门：竖向落手不许改值（否则"想上滑却改了 EV"）
  if (!sliderFile) {
    bad('找不到 ParameterSlider.swift');
  } else {
    const sliderSrc = fs.readFileSync(sliderFile, 'utf8');
    if (!/isHorizontalDrag/.test(sliderSrc) || !/directionDeadZone/.test(sliderSrc)) {
      bad('ParameterSlider 缺方向闸门（minimumDistance: 0 会把竖向滑动读成"手指 x 处的值"）');
    } else {
      ok('ParameterSlider 有方向闸门（竖向落手不改值）');
    }

    // d2) 触觉降频：滞后换档 + 节流（2026-09-18 真机反馈"拉到部分数值时一直触发咔"）
    //     根因是档位边界处的抖动让 `snapped != value` 每帧成立 —— 不是档位太密。
    const hyst = /\bhysteresisRatio\b/.test(sliderSrc)
      && /abs\(rawIndex - currentIndex\)\s*>=\s*Self\.hysteresisRatio/.test(sliderSrc);
    const throttle = /\btickThrottle\b/.test(sliderSrc)
      && /fireTickThrottled/.test(sliderSrc);
    const rawTick = /Haptics\.tick\(\)/.test(sliderSrc);
    // ⚠️ **量级守卫**（2026-09-18 真机复验的教训）：机制在、量太小 = 等于没做 ——
    // 55ms 节流在"每档 288ms 跨一档"的匀速拖动下完全拦不住快扫（复验实测约 17 声/秒）。
    // 所以这里不只查"有没有"，还查"够不够"。
    const numLit = name => {
      const m = new RegExp('\\b' + name + '\\s*:\\s*(?:Double|TimeInterval)\\s*=\\s*([0-9.]+)').exec(sliderSrc);
      return m ? parseFloat(m[1]) : null;
    };
    const hystVal = numLit('hysteresisRatio');
    const throttleVal = numLit('tickThrottle');
    if (!hyst) {
      bad('ParameterSlider 缺"滞后换档"（档位边界抖动会让触觉连响）');
    } else if (!throttle) {
      bad('ParameterSlider 缺触觉节流（tickThrottle / fireTickThrottled）');
    } else if (/if snapped != value \{[\s\S]{0,200}?Haptics\.tick\(\)/.test(sliderSrc)) {
      bad('ParameterSlider 的跨档触觉绕过了节流（直接调 Haptics.tick()）');
    } else if (hystVal === null || hystVal < 0.7) {
      bad('hysteresisRatio = ' + hystVal + ' 小于 0.7 —— 过渡带太窄，挡不住边界抖动（复验定稿 0.75）');
    } else if (throttleVal === null || throttleVal < 0.1) {
      bad('tickThrottle = ' + throttleVal + 's 小于 0.1s —— 短于约 1/4 档耗时，快扫时形同虚设（复验定稿 0.15s）');
    } else if (!rawTick) {
      bad('ParameterSlider 里连一处 Haptics.tick() 都没有了？归零反馈应该保留');
    } else {
      ok('ParameterSlider 触觉已降频且量级够（滞后 ' + hystVal + ' 档 + 节流 '
        + (throttleVal * 1000).toFixed(0) + 'ms，归零反馈保留）');
    }

    // l) 渲染源唯一（2026-09-18 docs/14 的第 ② 条查证）：thumb / 填充 / 数字必须同源于 value。
    //    若有人"为了跟手"把 thumb 改成跟 gesture.location.x，反而会制造真不同步
    //   （thumb 连续、填充与数字离散吸附）。跳动真因是 value 被回写改写，不是渲染源。
    const thumbBody = /private func thumbCenterX[\s\S]{0,500}?\n    \}/.exec(sliderSrc);
    const usesValue = !!thumbBody && /normalized\(value\)/.test(thumbBody[0]);
    const usesGesture = !!thumbBody && /(location|translation)/.test(thumbBody[0]);
    if (!usesValue || usesGesture) {
      bad('ParameterSlider 的 thumb 位置不是纯由 value 派生（第二个渲染源会造成真不同步）');
    } else {
      ok('ParameterSlider 渲染源唯一（thumb / 填充 / 数字同源于 value）');
    }
  }

  // e) 手势挂载点必须在整页 ZStack 上（第二轮真机反馈"上划两次只能呼出一个"）
  //    挂在 previewLayer 上时，滤镜条一出现就占掉用户上次起手的那块区域，
  //    第二次上划的触摸被滤镜条吃掉 → 手势收不到。这条断言防它被改回去。
  const previewBlock = /private var previewLayer: some View \{[\s\S]*?\n    \}/.exec(viewSrc8);
  const zstackGesture = /\.simultaneousGesture\(viewfinderSwipeGesture\)/.test(viewSrc8);
  if (!zstackGesture) {
    bad('找不到 .simultaneousGesture(viewfinderSwipeGesture) —— 手势没了？');
  } else if (previewBlock && /simultaneousGesture/.test(previewBlock[0])) {
    bad('手势又被挂回 previewLayer 了 —— 那样滤镜条一展开，第二次上划就会被它吃掉');
  } else {
    ok('上划/下划手势挂在整页 ZStack 上（滤镜条/场景条展开后仍能从它们上面起手）');
  }

  // f) 提前触发（滑够阈值立刻生效，不等松手）—— "上滑僵硬、要用力"的根因之一
  if (!/swipeDidTrigger/.test(viewSrc8) || !/shouldTriggerSwipe/.test(viewSrc8)) {
    bad('手势缺"提前触发"实现（swipeDidTrigger / shouldTriggerSwipe）—— 只在松手时判定会显得僵硬');
  } else if (!/onChanged[\s\S]{0,700}?shouldTriggerSwipe/.test(viewSrc8)) {
    bad('判定没放在 onChanged 里（必须滑够阈值即生效，不能只在 onEnded 判定）');
  } else {
    // 消息里**动态**拼当前阈值：写死数字会在调参后立刻变成过时文案
    //（本项目已多次栽在"注释/消息与代码不一致"上）
    const travelNow = numOf(viewSrc8, 'swipeMinTravel');
    ok('手势提前触发（滑够 ' + travelNow + 'pt 立刻生效，不等松手）');
  }

  // g) EV 滑条范围：必须用「UI 范围 ∩ 设备范围」，不许直接给设备范围
  //    iPhone 报 -8…+8 = 48 档 → 每档 7pt，1/3 档吸附完全感觉不到
  const clampFile = files.find(f => path.basename(f) === 'Numeric+Clamp.swift');
  if (!clampFile) {
    bad('找不到 Numeric+Clamp.swift');
  } else {
    const clampSrc = fs.readFileSync(clampFile, 'utf8');
    if (!/static let evUIRange/.test(clampSrc)) {
      bad('Numeric+Clamp 里没有 evUIRange（EV 滑条的 UI 范围常量）');
    } else if (!/intersected\(with: Float\.evUIRange\)/.test(viewSrc8)) {
      bad('EV 滑条没有取「UI 范围 ∩ 设备范围」—— 设备报 -8…+8 时 1/3 档会变成每档 7pt');
    } else {
      ok('EV 滑条范围 = UI(±2) ∩ 设备范围（13 档 / 每档约 28pt，吸附可感知）');
    }
  }

  // h) 状态改写必须留痕（2026-09-18 真机教训：静默改写让"上划走到哪个分支"无法对账）
  //    凡是会改写**多个**浮层状态的入口函数，体内必须同时出现 showToast 与 DebugLog。
  const stateToggles = [
    ['toggleSceneStyle', '场景·风格条（三入口共用，会连带收滤镜条/参数排）'],
    ['exposureCompensationTapped', '曝光补偿（会连带收滤镜条/场景·风格条）']
  ];
  let traceBad = false;
  for (const [fn, why] of stateToggles) {
    const body = methodBodyOf(vmSrc8, fn);
    if (!body) {
      bad('找不到 ' + fn + '()');
      traceBad = true;
      continue;
    }
    if (!/showToast\(/.test(body)) {
      bad(fn + '() 没有 toast —— ' + why + '：静默改写状态，用户看不见翻转');
      traceBad = true;
    } else if (!/DebugLog\.shared/.test(body)) {
      bad(fn + '() 没有 DebugLog —— ' + why + '：日志里也查不到这次改写');
      traceBad = true;
    }
  }
  // 连带收起必须在提示里说清（"已收起"字样），否则用户仍不知道自己的浮层去哪了
  const evBody = methodBodyOf(vmSrc8, 'exposureCompensationTapped');
  if (!evBody || !/已收起/.test(evBody)) {
    bad('exposureCompensationTapped 的提示没说清连带收起（应出现"已收起"字样）');
    traceBad = true;
  }
  if (!traceBad) {
    ok('改写浮层状态的入口都留了痕（toast + 日志），且连带收起在提示里说清');
  }

  // i) 误触闸门（2026-09-18 真机回归：横拖 EV 时被误判为下划把面板收起）
  //    手势挂整页 + 提前触发之后，横滑类控件的纵向抖动会命中"下划"。
  //    两条闸门都必须留着：① 编辑态禁言 ② 方向锁。
  const evEditGate = /!viewModel\.isExposureEditing/.test(viewSrc8);
  const axisLock = /swipeAxis/.test(viewSrc8) && /lockSwipeAxisIfNeeded/.test(viewSrc8);
  const editingState = /isExposureEditing/.test(vmSrc8)
    && /func exposureEditingChanged[\s\S]{0,600}?isExposureEditing\s*=/.test(vmSrc8);
  if (!editingState) {
    bad('exposureEditingChanged 没有把编辑态存下来（isExposureEditing）—— 闸门①无从判断');
  } else if (!evEditGate) {
    bad('手势缺闸门①（!viewModel.isExposureEditing）—— 横拖 EV 时会误触发下划');
  } else if (!axisLock) {
    bad('手势缺闸门②（方向锁 swipeAxis / lockSwipeAxisIfNeeded）—— 横滑条上的纵向抖动会误触发');
  } else {
    ok('误触闸门齐全（① EV 编辑态禁言 ② 方向锁），横滑类控件的抖动不会再误触发');
  }

  // j/k) EV 回写环的两道守卫（2026-09-18 用户诊断"反复跳动"，方案 docs/14）
  //      ① 拖动期间不回写（否则滑条被拽回旧档，滞后判定以旧值为基准 → 重复跨档 + 触觉重复响）
  //      ② 只接受"与最后推送值一致"的回写（丢弃队列里积压的旧值，否则松手后跳一下）
  const writebackGuarded = /\.sink \{ \[weak self\] value in[\s\S]{0,600}?guard !self\.isExposureEditing/.test(vmSrc8);
  const lastPushedSet = /func exposureEditingChanged[\s\S]{0,700}?lastPushedExposureBias\s*=/.test(vmSrc8);
  const lastPushedCompared = /lastPushedExposureBias[\s\S]{0,300}?abs\(Double\(sent\)/.test(vmSrc8);
  const lastPushedCleared = (vmSrc8.match(/lastPushedExposureBias\s*=\s*nil/g) || []).length >= 2;
  if (!writebackGuarded) {
    bad('硬件 EV 回写没有编辑态守卫（拖动中回写会把滑条拽回旧档 → 反复跳动）');
  } else if (!lastPushedSet || !lastPushedCompared) {
    bad('硬件 EV 回写没有"最后推送值"比对（拖动尾部积压的旧值会在松手后回放）');
  } else if (!lastPushedCleared) {
    bad('lastPushedExposureBias 没有在切模式 / 会话就绪时清空（会把来自设备的合法回写误吞）');
  } else {
    ok('EV 回写环两道守卫齐全（拖动中不回写 + 只接受最新推送值，且切换时清空记录）');
  }
}

/* ---------- 9. 功能面板（#10，2026-09-18） ---------- */
// 为什么要这一组：本件最容易错的两件事 ——
//   a) 把面板做成"底栈里的一行"（原型是盖住底栏的**模态浮层**，位置错了净可见账就全错）；
//   b) 面板里的格子少一个 / 顺序变了 / 某格没有 action（"点了没反应"，本项目明令禁止）。
// 另外面板高度是算出来的（7 格 = 4 列 × 2 行），净可见必须仍然 ≥ 50%。
console.log('\n[9] 功能面板');

const fnPanelFile = files.find(f => f.endsWith(path.join('Camera', 'UI', 'FunctionPanelView.swift')));
const topBarFile9 = files.find(f => f.endsWith(path.join('Camera', 'UI', 'TopBarView.swift')));

if (!fnPanelFile || !camViewFile || !vmFile || !topBarFile9 || !themeFile2) {
  bad('找不到 FunctionPanelView / CameraView / CameraViewModel / TopBarView / Theme');
} else {
  const panelSrc = fs.readFileSync(fnPanelFile, 'utf8');
  const viewSrc9 = fs.readFileSync(camViewFile, 'utf8');
  const vmSrc9 = fs.readFileSync(vmFile, 'utf8');
  const topSrc9 = fs.readFileSync(topBarFile9, 'utf8');
  const themeSrc9 = fs.readFileSync(themeFile2, 'utf8');

  // ① 面板必须是 overlay（盖住底栏），不能是底栈里的一行
  if (!/\.overlay\(alignment: \.bottom\)[\s\S]{0,900}?FunctionPanelView\(/.test(viewSrc9)) {
    bad('功能面板不是 bottom 对齐的 overlay —— 原型是盖住底栏的模态浮层，不是底栈一行');
  } else {
    ok('功能面板是 bottom 对齐的模态浮层（盖住底栏，不参与底栈布局）');
  }

  // ② 7 格、顺序、且每格都有 action；阶段标记必须已移除（用户 2026-09-18 拍板）
  const labels = ['实况', '画幅比', '闪光灯', '倒计时', '高亮增益', '设置', 'HUD'];
  const labelIndexes = labels.map(l => viewSrc9.indexOf('label: "' + l + '"'));
  const missingLabel = labels.filter((l, i) => labelIndexes[i] < 0);
  const orderOK = labelIndexes.every((v, i) => i === 0 || v > labelIndexes[i - 1]);
  const fnActionCount = (viewSrc9.match(/\{ viewModel\.fn\w+Tapped\(\) \}/g) || []).length;
  if (missingLabel.length) {
    bad('功能面板缺格：' + missingLabel.join(' / '));
  } else if (!orderOK) {
    bad('功能面板格子顺序与原型不符（应为：' + labels.join(' → ') + '）');
  } else if (fnActionCount < labels.length) {
    // 7 格里每格都要有 action；计数会多算 foot 的「简易模式」那一处，所以只查下限
    bad('功能面板有格子没接 action（匹配到 ' + fnActionCount + ' 个，至少应 ' + labels.length + '）');
  } else if (/label: "阶段标记"/.test(viewSrc9)) {
    // ⚠️ 只查代码（`label:` 字面量），不查"阶段标记"这四个字 ——
    // 注释里本来就要解释它为什么被去掉，用宽匹配会被自己的注释绊倒（原型侧也踩过同款）
    bad('「阶段标记」又回来了 —— 用户 2026-09-18 拍板去掉（研发工具，真机无价值）');
  } else {
    ok('功能面板 7 格齐全、顺序正确、每格都有 action（无「阶段标记」）');
  }

  // ③ 开面板要收起其余扩展浮层（原型 collapseAll）
  const toggleFnBody = methodBodyOf(vmSrc9, 'toggleFunctionPanel');
  if (!toggleFnBody || !/collapseOverlays\(\)/.test(toggleFnBody)) {
    bad('toggleFunctionPanel 没有收起其余扩展浮层（两层浮层叠加会破净可见底线）');
  } else {
    ok('开功能面板会收起其余扩展浮层（collapseOverlays）');
  }

  // ④ 五项拍摄现场设置必须落盘（原型存 LS_SHOOT 的 state.fn）
  const fnKeys = (vmSrc9.match(/lumen\.camera\.fn\./g) || []).length;
  if (fnKeys < 5) {
    bad('功能面板的落盘键只有 ' + fnKeys + ' 个（应有 5：live / ratio / flash / timer / hdr）');
  } else {
    ok('功能面板 5 项设置都落盘（lumen.camera.fn.*）');
  }

  // ⑤ 顶栏第三颗图标必须是 ⠿（设置已收进面板）
  if (!/circle\.grid\.3x3\.fill/.test(topSrc9)) {
    bad('顶栏没有 ⠿ 图标（circle.grid.3x3.fill）—— 原型第三颗是功能面板入口');
  } else if (/gearshape/.test(topSrc9)) {
    bad('顶栏还有 gearshape —— 「设置」应已收进功能面板第 6 格');
  } else if (!/onFunctionPanelTap/.test(topSrc9)) {
    bad('顶栏缺少 onFunctionPanelTap 回调');
  } else {
    ok('顶栏第三颗图标是 ⠿（设置已收进面板），回调命名正确');
  }

  // ⑥ 画幅比遮幅：存在 + 不接收触摸 + 由 fnRatio 驱动 + **窗中心钉全屏中心**
  //    （2026-09-19 backlog ⑤ 修法 A）
  //    为什么要守这个偏置：安全区上下**不等**（刘海/灵动岛 62 vs Home 指示条 34），
  //    "两块黑边等高"会让窗中心落在安全区中心（451），比全屏中心（437）**低 14pt** ——
  //    这就是用户看到的"1:1 遮幅偏下"。
  //    这条算式、钳制、以及"日志能直接核对"三件事被改掉任何一件，真机上都会重新偏 ——
  //    而静态检查完全拦得住。（用户 2026-09-19 定案：偏置 =（上 − 下）/ 2，即上移 14pt。）
  const maskCallOK = /FrameRatioMask\([\s\S]{0,140}?ratio: viewModel\.fnRatio[\s\S]{0,200}?pinsWindowToScreenCenter: !viewModel\.isZoomOn/
    .test(viewSrc9);
  const maskBody = /private struct FrameRatioMask[\s\S]*?\n}/.exec(viewSrc9);
  const maskSrc = maskBody ? maskBody[0] : null;
  const maskUsesScreenInsets = !!maskSrc && /ScreenSafeArea\.insets/.test(maskSrc);
  const maskBiasFormula = !!maskSrc && /\(insets\.top - insets\.bottom\) \/ 2/.test(maskSrc);
  const maskBiasClamped = !!maskSrc && /min\(max\(rawBias, -equalBar\), equalBar\)/.test(maskSrc);
  // ⚠️ 这条要守的是"**日志里能直接读到两个中心**"这个**能力**，不是"出现过某几个字"：
  //    注释里也会写"全屏中心"这几个字，只按词匹配会漏（本检查自己踩过一次，被变异测试抓出来）。
  //    所以要求日志同时打出「窗中心（全屏）」与**由 screenHeight / 2 算出的对照值**。
  const maskLogsBothCenters = !!maskSrc
    && /窗中心（全屏）/.test(maskSrc) && /screenHeight \/ 2/.test(maskSrc);
  const maskNoHit = !!maskSrc && /allowsHitTesting\(false\)/.test(maskSrc);

  if (!maskCallOK) {
    bad('取景器里的遮幅调用不对（应为 `FrameRatioMask(ratio: viewModel.fnRatio, '
      + 'pinsWindowToScreenCenter: !viewModel.isZoomOn)`）');
  } else if (!maskSrc) {
    bad('找不到 `private struct FrameRatioMask`（改名了？自检需要同步）');
  } else if (!maskUsesScreenInsets) {
    bad('遮幅没有读窗口安全区（`ScreenSafeArea.insets`）—— 窗中心钉不到全屏中心');
  } else if (!maskBiasFormula) {
    bad('遮幅的偏置不是 `(上安全区 − 下安全区) / 2` —— 1:1 遮幅会重新偏下 '
      + '（安全区上 62 / 下 34 ⇒ 差 14pt）');
  } else if (!maskBiasClamped) {
    bad('遮幅偏置没有钳制（`min(max(rawBias, -equalBar), equalBar)`）'
      + ' —— 极端比例下会把黑边推成负值');
  } else if (!maskLogsBothCenters) {
    bad('遮幅日志没有同时打出"窗中心（全屏）"与"全屏中心" —— Mac 侧就没法读一行核对');
  } else if (!maskNoHit) {
    bad('遮幅会接收触摸 —— 原型是 pointer-events:none（点黑边区照样对焦）');
  } else {
    ok('画幅比遮幅：由 fnRatio 驱动、窗中心钉全屏中心（安全区差 / 2，有钳制）、不接收触摸、日志可核对');
  }

  // ⑦ 面板高度账 + 净可见（目标机型；iPhone SE 不在目标范围，不查）
  const panelHeight = (() => {
    const t = n => {
      const m = new RegExp('\\b' + n + '\\s*:\\s*CGFloat\\s*=\\s*([0-9.]+)').exec(themeSrc9);
      return m ? parseFloat(m[1]) : null;
    };
    const parts = {
      top: t('functionPanelTopPadding'), bottom: t('functionPanelBottomPadding'),
      circle: t('functionGlyphCircleSide'), inner: t('functionCellInnerSpacing'),
      label: t('functionLabelHeight'), rowGap: t('functionGridRowSpacing'),
      footGap: t('functionFootTopSpacing'), footTop: t('functionFootTopPadding'),
      link: t('functionLinkHeight'), footBottom: t('functionFootBottomPadding')
    };
    const miss = Object.keys(parts).filter(k => parts[k] === null);
    if (miss.length) return { error: '读不到面板令牌：' + miss.join(' / ') };
    const cell = parts.circle + parts.inner + parts.label;
    const grid = 2 * cell + parts.rowGap;
    const foot = parts.footGap + 0.5 + parts.footTop + parts.link + parts.footBottom;
    return { value: parts.top + grid + foot + parts.bottom };
  })();

  if (panelHeight.error) {
    bad(panelHeight.error);
  } else {
    // 与 Theme.Size.functionPanelHeight 的注释一致（16 + 162 + 57.5 + 6 = 241.5）
    ok('功能面板高度 ' + panelHeight.value.toFixed(1) + 'pt（= 上内边距 + 2 行网格 + foot + 下内边距）');

    // 净可见 = (屏高 − 安全区 96) − 顶栏 66 − 面板高 − 面板底边距 8，口径与原型 net/H 一致
    const targets = [
      { name: 'iPhone 16 Pro（874）', screen: 874 },
      { name: 'iPhone 16 / 15（852）', screen: 852 },
      { name: 'iPhone 14（844）', screen: 844 }
    ];
    let visBad = false;
    for (const d of targets) {
      const safe = d.screen - 96;                       // 上 62 + 下 34（iPhone 16 起）
      const net = safe - 66 - panelHeight.value - Theme_Size_edgeInset(themeSrc9);
      const pct = net / d.screen * 100;
      const label = d.name + ' 面板态净可见 ' + pct.toFixed(1) + '%';
      if (pct < 50) { bad(label + '（低于 50% 底线）'); visBad = true; }
      else ok(label);
    }
    if (!visBad) ok('面板态净可见在目标机型上均 ≥ 50%');
  }
}

/** 读面板贴边距离（用于净可见账；独立出来是为了在上面那段里也能用 */
function Theme_Size_edgeInset(src) {
  const m = /\bfunctionPanelEdgeInset\s*:\s*CGFloat\s*=\s*([0-9.]+)/.exec(src);
  return m ? parseFloat(m[1]) : 8;
}

/* ---------- 10. 视频格式芯片（#11，2026-09-18） ---------- */
// 为什么要这一组：
//   a) 芯片**顶替**三图标，两者都在 73pt 那一格里 —— 顶替关系错一半会出现"都不显示/都显示"，
//      而芯片宽度写死数字会让**模式条居中**失效（模式条靠左右两侧等宽）；
//   b) 码率表有 12 个组合，**缺键会静默落到兜底码率**，时长估算错得看不出来；
//   c) 存储胶囊在录制类模式换成长文本 —— **预留宽度必须同步换形态**，
//      否则会复发 Mac 侧实测过的"启动后 73→95pt 跳变"（那次跳变还导致几何量错）。
console.log('\n[10] 视频格式芯片');

const formatChipFile = files.find(f => f.endsWith(path.join('Camera', 'UI', 'FormatChipView.swift')));
const formatCatalogFile = files.find(f => path.basename(f) === 'VideoFormatCatalog.swift');

if (!formatChipFile || !formatCatalogFile || !topBarFile9 || !vmFile) {
  bad('找不到 FormatChipView / VideoFormatCatalog / TopBarView / CameraViewModel（改名了？自检需要同步）');
} else {
  const chipSrc = fs.readFileSync(formatChipFile, 'utf8');
  const catalogSrc = fs.readFileSync(formatCatalogFile, 'utf8');
  const topSrc10 = fs.readFileSync(topBarFile9, 'utf8');
  const vmSrc10 = fs.readFileSync(vmFile, 'utf8');

  // ① 芯片宽度必须**引用令牌**（不许写死数字）—— 模式条居中依赖它
  if (!/\.frame\(minWidth: Theme\.Size\.topBarSideWidth\)/.test(chipSrc)) {
    bad('芯片没有钉成 topBarSideWidth（写死数字会让模式条的居中失效）');
  } else {
    ok('芯片最小宽引用 Theme.Size.topBarSideWidth（模式条居中不受影响）');
  }

  // ② 顶替关系：录制类模式下芯片出现、三图标隐藏
  const chipInTopBar = /if mode\.isRecordingBased \{[\s\S]{0,400}?FormatChipView\(/.test(topSrc10);
  const iconsInElse = /if mode\.isRecordingBased \{[\s\S]{0,900}?\} else \{[\s\S]{0,200}?topBarIcons/.test(topSrc10);
  if (!chipInTopBar || !iconsInElse) {
    bad('顶替关系不完整：应为"录制类模式 → 芯片，其它 → 三图标"（现在不是 if/else 关系）');
  } else {
    ok('右上角是顶替关系（录制类模式显示芯片，其它模式显示三图标）');
  }

  // ③ 选择器选项：分辨率 3 项 + 帧率 4 项
  const resCases = (catalogSrc.match(/case p720|case p1080|case uhd4K/g) || []).length;
  const fpsCases = (catalogSrc.match(/case fps24|case fps30|case fps60|case fps120/g) || []).length;
  if (resCases !== 3 || fpsCases !== 4) {
    bad('档位数量不对：分辨率 ' + resCases + ' 项（应 3）/ 帧率 ' + fpsCases + ' 项（应 4）');
  } else {
    ok('档位齐全（分辨率 3 项 / 帧率 4 项）');
  }

  // ④ 码率表：12 个值全正，且**键集合与档位集合一致**（缺键会静默走兜底值）
  const tableBlock = /bitrateTable[\s\S]*?\n    \]/.exec(catalogSrc);
  if (!tableBlock) {
    bad('找不到码率表 bitrateTable');
  } else {
    const nums = (tableBlock[0].match(/:\s*[0-9]+(?=\s*[,}\]])/g) || [])
      .map(x => parseFloat(x.replace(/[:\s]/g, '')));
    const nonPositive = nums.filter(n => !(n > 0)).length;
    const missingRow = ['.p720', '.p1080', '.uhd4K'].filter(r => !tableBlock[0].includes(r));
    if (nums.length !== 12) {
      bad('码率表有 ' + nums.length + ' 个值（应为 12 = 3 分辨率 × 4 帧率）—— 缺键会静默落到兜底码率');
    } else if (nonPositive > 0) {
      bad('码率表有 ' + nonPositive + ' 个非正值');
    } else if (missingRow.length) {
      bad('码率表缺分辨率行：' + missingRow.join(' / '));
    } else {
      ok('码率表 12 个值齐全且全为正（' + Math.min(...nums) + ' ~ ' + Math.max(...nums) + ' Mbps）');
    }
  }

  // ⑤ 落盘 2 键
  const fmtKeys = (vmSrc10.match(/lumen\.camera\.fmt\./g) || []).length;
  if (fmtKeys < 2) {
    bad('视频格式落盘键只有 ' + fmtKeys + ' 个（应有 2：res / fps）');
  } else {
    ok('分辨率与帧率都落盘（lumen.camera.fmt.res / .fps）');
  }

  // ⑥ 与功能面板互斥（两方向）
  const popoverMutex = /func formatChipTapped[\s\S]{0,600}?dismissFunctionPanelIfNeeded\(\)/.test(vmSrc10)
    && /func toggleFunctionPanel[\s\S]{0,600}?dismissFormatSelectorIfNeeded\(\)/.test(vmSrc10);
  if (!popoverMutex) {
    bad('格式选择器与功能面板没有互斥（原型两处各自关闭对方）');
  } else {
    ok('格式选择器与功能面板互斥（两方向都有）');
  }

  // ⑦ 存储胶囊：录制类模式的预留宽度必须同步换形态（防"启动后跳宽"复发）
  const reservation = /private var storageWidthReservation[\s\S]{0,400}?mode\.isRecordingBased/.test(topSrc10);
  const longTextDeclared = /≈\s*23h 59m · 999\.99 GB/.test(topSrc10);
  const storageFromVM = /storageText: viewModel\.storageChipText/.test(
    fs.readFileSync(camViewFile, 'utf8')
  );
  if (!reservation || !longTextDeclared) {
    bad('存储胶囊的预留宽度没有随模式切换 —— 录制类模式的长文本会撑宽胶囊（73→95pt 跳变复发）');
  } else if (!storageFromVM) {
    bad('CameraView 没有把 viewModel.storageChipText 传进顶栏（文字与模式要对齐）');
  } else {
    ok('存储胶囊文本随模式切换，且预留宽度同步换形态（长文本不会跳宽）');
  }
}

/* ---------- 11. 焦段切镜头（B1，2026-09-18；2026-09-19 按真机实测改映射） ---------- */
// 为什么要这一组：
//   a) 档位 → zoom 的映射写反/漏改会让"点 120mm 反而拉远"。
//      ⚠️ 2026-09-19 真机实测把第一版的"mm ÷ 基准"推翻了（基准是机型相关的，实测 12mm），
//      改成**按镜头角色从设备读**，详见 ① 那段注释；
//   b) `ramp` 必须在 lockForConfiguration 内（否则抛 NSGenericException）→ 它只允许出现在
//      CaptureDeviceConfigurator（= 铁律 2"唯一锁"）；
//   c) **"切镜头不重建会话"是本件的核心不变量** —— 一旦有人在这里 beginConfiguration
//      或增删 input，就会平白引入重建停顿（那套是模式切换用的）。
console.log('\n[11] 焦段切镜头 (B1)');

const focalFile = files.find(f => path.basename(f) === 'FocalPreset.swift');
const capFile = files.find(f => path.basename(f) === 'CaptureCapabilities.swift');
const configuratorFile = files.find(f => path.basename(f) === 'CaptureDeviceConfigurator.swift');
const stripFile = files.find(f => path.basename(f) === 'FocalStripView.swift');

if (!focalFile || !capFile || !configuratorFile || !stripFile) {
  bad('找不到 FocalPreset / CaptureCapabilities / CaptureDeviceConfigurator / FocalStripView');
} else {
  const focalSrc = fs.readFileSync(focalFile, 'utf8');
  const capSrc = fs.readFileSync(capFile, 'utf8');
  const cfgSrc = fs.readFileSync(configuratorFile, 'utf8');
  const stripSrc = fs.readFileSync(stripFile, 'utf8');
  const sessionSrc = fs.readFileSync(
    files.find(f => path.basename(f) === 'CaptureSessionController.swift'), 'utf8'
  );

  // ① 档位映射：**按镜头角色从设备读**（2026-09-19 修订 · 不再做 `mm ÷ 基准`）
  //
  // 为什么要重写这条：第一版是"等效焦距 ÷ 基准"的纯算术，真机实测把它的前提推翻了 ——
  // 某机 `switchOver = [2.000, 10.000]`，而 2.0 / 10.0 正对 24mm / 120mm 两颗镜头
  // ⇒ 虚拟基准是 **12mm**，不是文档假设的 13mm。整表偏小约 8%；最要命的是 120mm 档
  // 算出的 9.231 **落在 switchOver[1] = 10.0 之下** → 系统不切长焦、只用主摄数码放大
  // （画质崩），而 UI 却显示"已切到 120mm"。
  //
  // 现在按角色读：13→超广角原生 / 24→广角原生 / 48→广角原生×2 / 120→长焦原生。
  // 于是这条检查守四件事：
  //   a) 角色表齐全（13/24/48/120 → 四个角色），且**没有残留 mm 除法**；
  //   b) 原生阶梯 = `[1.0] + virtualDeviceSwitchOverVideoZoomFactors`；
  //   c) 在真机实测那个配置（三摄 `[2.0, 10.0]`）上复算：必须严格递增，
  //      且 24 档 == switchOver[0]、**120 档 == switchOver[last]**（本次修法的核心不变量）；
  //   d) "角色超出阶梯长度 → 判不可用"的守卫在（无长焦机型要把 120mm 档置灰）。
  //
  // ⚠️ 负向判据（"没有残留 mm 除法"）只在**代码**里找，不把注释算进来 ——
  // 注释里恰恰应该写清"为什么不能用它"（本项目在这上面绊倒过两次，见 `docs/12` 第九轮）。
  const capCode = capSrc.replace(/\/\/[^\n]*/g, '');

  const roleMap = {};
  // ⚠️ 两处都踩过坑，别再简化：
  //   ① 选项**长的在前** + 结尾 `\b`：交替匹配按书写顺序尝试，短名会**前缀吃掉**长名
  //      （`wide` 吃掉 `mainCrop` 之类）→ 解析出的角色是错的，本检查当场 FAIL。
  //   ② **必须支持 `case 35, 48: return .mainCrop` 这种合并写法**：同一角色的多个档位
  //      写在一个 case 里是很自然的 Swift 写法，检查脚本要跟着走，**不能让 Swift 迁就正则**
  //      （这正是"守卫自己写错"的典型：第一版只认单值，于是报了假的 FAIL）。
  for (const m of focalSrc.matchAll(/case ([0-9,\s]+):\s*return \.([A-Za-z0-9]+)\b/g)) {
    for (const mm of m[1].split(',').map(s => s.trim()).filter(Boolean)) {
      roleMap[mm] = m[2];
    }
  }
  const ladderOk = /\[1\.0\]\s*\+\s*device\.virtualDeviceSwitchOverVideoZoomFactors/.test(capCode);
  const noMmDivision = !/millimeters\s*\/|forFocalMillimeters|baseMillimeters/.test(capCode);
  // 裁切档（35 / 48）必须走"主摄原生 × FocalPreset.mainCropFactor"，不许写死倍数
  const hasRoleLookup = /nativeZoom\(of: \.wide, on: device\)[\s\S]{0,160}?return wide \* \(focal\.mainCropFactor \?\? 1\)/
      .test(capCode)
    && /func nativeZoom\(of role: FocalLensRole, on device: AVCaptureDevice\)/.test(capCode);
  const ladderGuard = /guard index < ladder\.count/.test(capCode);
  const mmCount = (focalSrc.match(/FocalPreset\(/g) || []).length;

  // 角色映射必须**逐条精确**（只数条数不够）。
  // 为什么单列这一条：`120mm → .telephoto` 是 B1 那次真机事故的命门（旧算法把它算成 9.231，
  // 落在 switchOver[1] 之下 → 系统不切长焦，只用主摄数码放大）。
  // 若有人把它改回 `.wide`（或任何不到长焦的角色），单调性检查只会报"非递增"、指不到根因。
  const expectedRoles = {
    '13': 'ultraWide', '24': 'wide', '35': 'mainCrop', '48': 'mainCrop', '120': 'telephoto'
  };
  const expectedTierCount = Object.keys(expectedRoles).length;   // 5
  const roleMismatch = Object.keys(expectedRoles)
    .filter(mm => roleMap[mm] !== expectedRoles[mm])
    .map(mm => mm + '→' + (roleMap[mm] || '缺') + '（应 ' + expectedRoles[mm] + '）');

  if (mmCount !== expectedTierCount) {
    bad('焦段档位数是 ' + mmCount + '（应为 ' + expectedTierCount + '：'
      + Object.keys(expectedRoles).join('/') + '）');
  } else if (Object.keys(roleMap).length !== expectedTierCount) {
    bad('焦段角色表不全（实际解析到 ' + Object.keys(roleMap).length + ' 条 '
      + JSON.stringify(roleMap) + '）');
  } else if (roleMismatch.length) {
    bad('档位角色映射不对：' + roleMismatch.join('、')
      + ' —— 120mm 必须是长焦，35 / 48 必须是主摄裁切，否则要么不切长焦、要么语义漂移');
  } else if (!ladderOk) {
    bad('原生阶梯不是 `[1.0] + virtualDeviceSwitchOverVideoZoomFactors`');
  } else if (!noMmDivision) {
    bad('还有 `mm ÷ 基准` 的残留（millimeters / forFocalMillimeters / baseMillimeters）—— '
      + '基准是机型相关的（实测 12mm 而非 13mm），除法会让 120mm 档落在切换点之下');
  } else if (!hasRoleLookup) {
    bad('裁切档没有按"主摄原生视场 × FocalPreset.mainCropFactor"取（不许写死倍数）');
  } else if (!ladderGuard) {
    bad('缺"角色超出阶梯长度 → 判不可用"的守卫（无长焦机型会把 120mm 档当成可用）');
  } else {
    // c) 在真机实测配置上复算（三摄：超广角 / 广角 / 长焦）
    const ladder = [1.0, 2.0, 10.0];                 // = [1.0] + switchOver
    const switchOver = ladder.slice(1);              // 实测 [2.000, 10.000]
    const roleIndex = { ultraWide: 0, wide: 1, telephoto: 2 };
    const NOMINAL_MAIN_MM = 24;                      // 标称主摄（与 FocalPreset.mainCropFactor 同源）
    const tierIds = Object.keys(expectedRoles);
    const tiers = tierIds.map(mm => {
      const role = roleMap[mm];
      const nominal = parseFloat(mm);
      if (role === 'mainCrop') {
        return { mm: mm, value: ladder[roleIndex.wide] * (nominal / NOMINAL_MAIN_MM) };
      }
      const i = roleIndex[role];
      return { mm: mm, value: i === undefined || i >= ladder.length ? null : ladder[i] };
    });
    const values = tiers.map(t => t.value);
    const increasing = values.every((v, i) =>
      i === 0 || (v !== null && values[i - 1] !== null && v > values[i - 1]));
    // 两条核心不变量（都拿 **switchOver** 当基准，不是阶梯的第 0 级 = 1.0）：
    //   24mm == switchOver[0]（广角原生）；120mm == switchOver[last]（长焦原生）
    const wideOK = values[1] !== null && Math.abs(values[1] - switchOver[0]) < 1e-9;
    const teleOK = values[4] !== null
      && Math.abs(values[4] - switchOver[switchOver.length - 1]) < 1e-9;
    const text = tiers.map(t => t.mm + '→' + (t.value === null ? '不可用' : t.value.toFixed(3))).join(' / ');

    if (!increasing) {
      bad('档位 zoom 不是严格递增：' + text);
    } else if (!wideOK) {
      bad('24mm 档 != switchOver[0]（应 ' + switchOver[0].toFixed(3) + '，实际 '
        + values[1].toFixed(3) + '）—— 没落在广角原生视场上');
    } else if (!teleOK) {
      bad('120mm 档没落在长焦原生视场（应 switchOver[last] = '
        + switchOver[switchOver.length - 1].toFixed(3) + '，实际 ' + String(values[4])
        + '）—— 系统不会切长焦，只会主摄数码放大');
    } else {
      ok('档位映射按镜头角色从设备读（三摄 [2.0, 10.0] 复算：' + text + '）');
    }
  }

  // ①b 置灰判据 + 拓扑日志（2026-09-19 Mac 侧预检要求）
  //     为什么：`caps.zoom.min` 在单广角回退机型上**也是 1.0**，区分不了 "1.0 = 最广视场"
  //     还是 "1.0 = 广角视场"。拿它当判据 → 13mm 档永远"看起来可用" → 点了画面不动。
  //     所以必须是"两条互补探测"，且拓扑要能在日志里读出来（④ 的核法）。
  //     ⚠️ 探测的实际实现现在是共用的 `hasLens(_:on:)`（`hasUltraWideLens` / `hasTelephotoLens`
  //        都委托它），所以这里跟着看那个函数体，而不是看那两个一行的包装。
  const probeBody = methodBodyOf(capSrc, 'hasLens');
  const probesDelegated = /hasUltraWideLens[\s\S]{0,240}?hasLens\(\.builtInUltraWideCamera/
    .test(capCode);
  const probeByConstituents = !!probeBody
    && /constituentDevices[\s\S]{0,200}?deviceType == type/.test(probeBody);
  const probeByDiscovery = !!probeBody
    && /DiscoverySession[\s\S]{0,300}?deviceTypes: \[type\]/.test(probeBody);
  // `capCode` 已在 ① 里剥好注释（复用，避免重复声明）
  const judgesByZoomMin = /zoom\s*\??\.\s*min/.test(capCode);
  const hasTopologyDesc = /func zoomTopologyDescription/.test(capCode)
    && /virtualDeviceSwitchOverVideoZoomFactors/.test(capCode)
    && /档位=/.test(capCode);
  const topologyLogged = /zoomTopologyDescription\(of:/.test(sessionSrc);

  if (!probeBody) {
    bad('找不到 CaptureCapabilities.hasLens（"有没有这颗镜头"的探测实现）');
  } else if (!probesDelegated) {
    bad('hasUltraWideLens 没有委托给 hasLens（探测实现被挪走了？自检需要同步）');
  } else if (!probeByConstituents) {
    bad('"有没有这颗镜头"缺 constituent 那条（虚拟设备才知道当前设备里到底有哪几颗）');
  } else if (!probeByDiscovery) {
    bad('"有没有这颗镜头"缺 DiscoverySession 兜底那条 —— constituentDevices 对非虚拟设备'
      + '可能返回空，漏判会让该档不置灰（"点了没反应"）');
  } else if (judgesByZoomMin) {
    bad('拿 caps.zoom.min 当置灰判据了 —— 单广角机型上它同样是 1.0，区分不了不同视场');
  } else {
    ok('置灰判据是两条互补探测（constituent + DiscoverySession），没拿 zoom.min 当判据');
  }

  if (!hasTopologyDesc) {
    bad('CaptureCapabilities 缺 zoomTopologyDescription，或它没把"档位→zoom"打出来'
      + '（那行日志是核对档位映射的唯一硬数据，见 ①）');
  } else if (!topologyLogged) {
    bad('会话启动路径没有打印变焦拓扑 —— Mac 侧就没法"读一次冷启动日志"核对档位映射');
  } else {
    ok('变焦拓扑在会话启动时打一行日志（角色 + switchOver + 阶梯 + 各档解析值 + 不可用档）');
  }

  // ② 必须用 ramp（硬设 = 直接跳，失去本件的意义）
  if (!/device\.ramp\(toVideoZoomFactor:/.test(cfgSrc)) {
    bad('CaptureDeviceConfigurator 里没有 ramp(toVideoZoomFactor:) —— 变焦会是硬跳');
  } else {
    ok('运行时变焦走 ramp（平滑）而不是硬设 videoZoomFactor');
  }

  // ③ ramp 只允许出现在 configurator（铁律 2：唯一锁的地方）
  const rampFiles = files.filter(f => /\.ramp\(toVideoZoomFactor:/.test(fs.readFileSync(f, 'utf8')))
    .map(f => path.basename(f));
  if (rampFiles.length !== 1 || rampFiles[0] !== 'CaptureDeviceConfigurator.swift') {
    bad('ramp 出现在 ' + rampFiles.join(' / ') + ' —— 它必须在 lockForConfiguration 内调用，'
      + '只允许出现在 CaptureDeviceConfigurator');
  } else {
    ok('ramp 只出现在 CaptureDeviceConfigurator（在唯一锁内调用，符合铁律 2）');
  }

  // ④ clamp 到设备能力（越界赋值是抛异常）
  if (!/CaptureCapabilities\.zoomRange\(of:/.test(cfgSrc)) {
    bad('applyZoomRamp 没有用 CaptureCapabilities.zoomRange 做 clamp（越界赋值会抛异常）');
  } else {
    ok('变焦前先 clamp 到设备能力区间（统一走 zoomRange，两处口径不漂）');
  }

  // ⑤ **不重建会话**：变焦路径里不得出现配置变更 / input 增删
  const zoomBody = methodBodyOf(sessionSrc, 'setZoomFactor');
  if (!zoomBody) {
    bad('找不到 CaptureSessionController.setZoomFactor');
  } else if (/beginConfiguration|addInput|removeInput|commitConfiguration/.test(zoomBody)) {
    bad('setZoomFactor 里出现了会话配置变更 —— 切镜头**不该重建会话**（那套是模式切换用的）');
  } else if (!/applyFocal/.test(sessionSrc)) {
    bad('找不到 applyFocal（档位 → zoom 的换算入口）');
  } else {
    ok('切镜头路径只做 lock → ramp → unlock（无 beginConfiguration / input 增删）');
  }

  // ⑥ 焦段条命中高仍为条高 44（药丸视觉 30，别把命中高改成药丸高）
  if (!/\.frame\(height: Theme\.Size\.focalStripHeight\)[\s\S]{0,120}?contentShape\(Rectangle\(\)\)/.test(stripSrc)) {
    bad('焦段药丸的命中高不再是条高 44（HIG 下限 44，改回药丸高 30 就掉下去了）');
  } else {
    ok('焦段药丸命中高仍为 44（视觉 44×30 不变，热区借条内空白）');
  }

  // ⑦ 置灰：不可用档位**仍可点**（灰 + 可点 + 有解释），不是 disabled
  const grayed = /unavailableIds/.test(stripSrc);
  const notDisabled = !/\.disabled\([^)]*unavailable/.test(stripSrc);
  const vmExplains = /unavailableFocalIds\.contains\(preset\.id\)[\s\S]{0,600}?showToast/.test(
    fs.readFileSync(vmFile, 'utf8')
  );
  if (!grayed) {
    bad('FocalStripView 缺 unavailableIds（不可用档位没有置灰）');
  } else if (!notDisabled) {
    bad('不可用档位被 disabled 了 —— 产品约束要求"灰但仍可点并给出原因"');
  } else if (!vmExplains) {
    bad('点了不可用档位没有 toast 说明原因（"点了没反应"违反产品约束）');
  } else {
    ok('不可用档位置灰但仍可点，且点了给 toast 说明原因');
  }

  // ⑧ 量级守卫（`docs/11` 第七节那条判据的推广：**机制在但量太小等于没做**）
  const rampBody = methodBodyOf(cfgSrc, 'applyZoomRamp');
  const rampDurationMatch = /\bzoomRampDuration\s*:\s*TimeInterval\s*=\s*([0-9.]+)/.exec(cfgSrc);
  const rampDuration = rampDurationMatch ? parseFloat(rampDurationMatch[1]) : null;
  if (!rampBody) {
    bad('找不到 CaptureDeviceConfigurator.applyZoomRamp');
  } else if (!/log2\(/.test(rampBody)) {
    bad('applyZoomRamp 的 rate 不是由 log2(目标/当前) 算出来的 —— 固定 rate 会让跨档越大越慢'
      + '（13→120 要 1s 以上，"点一下平滑过去"的手感就没了）');
  } else if (rampDuration === null) {
    bad('读不到 zoomRampDuration（改名了？自检需要同步）');
  } else if (rampDuration < 0.2 || rampDuration > 0.6) {
    bad('zoomRampDuration = ' + rampDuration + 's 越界（应 ∈ [0.2, 0.6]）：'
      + '太小 ≈ 硬跳（本件的意义没了）、太大 ≈ 拖沓');
  } else {
    ok('变焦量级守卫：rate 走 log2、时长 ' + rampDuration + 's ∈ [0.2, 0.6]');
  }

  // ⑨ 双来源守卫：两个变焦入口**不得互相调用**（2026-09-19 Mac 侧预检要求）
  //    两个口径：applyZoomLocked = CapturePreset.zoomFactor（预设链路，P4 后由 EditRecipe 驱动）
  //              applyZoomRamp   = 焦段档位（UI 真相）
  //    互相调用 → P4 注入预设时"两个来源抢 videoZoomFactor"，画面来回跳且极难归因。
  const lockedBody = methodBodyOf(cfgSrc, 'applyZoomLocked');
  const rampCallsLocked = !!rampBody && /applyZoomLocked\s*\(/.test(rampBody);
  const lockedCallsRamp = !!lockedBody && /applyZoomRamp\s*\(/.test(lockedBody);
  const lockedHardSets = !!lockedBody && /device\.videoZoomFactor\s*=/.test(lockedBody);
  if (!lockedBody) {
    bad('找不到 CaptureDeviceConfigurator.applyZoomLocked');
  } else if (rampCallsLocked || lockedCallsRamp) {
    bad('applyZoomRamp 与 applyZoomLocked 互相调用了 —— 两个变焦来源会抢 videoZoomFactor');
  } else if (!lockedHardSets) {
    bad('applyZoomLocked 不再是配置期的硬设（device.videoZoomFactor =）'
      + ' —— 会话刚建起来不需要"过程"');
  } else {
    ok('双来源守卫：applyZoomRamp ⇄ applyZoomLocked 无互相调用，配置期仍是硬设');
  }

  // ⑪ 裁切档系数同源（2026-09-19 加 35mm 档时新增）
  //     35 与 48 都是"主摄内部的数码裁切"，比例必须由 `mm ÷ 24` **一条式子**给 ——
  //     不许一处写 ×2、另一处写 1.46（那种"两个来源"必然只改一处）。
  const cropFactorSource = /var mainCropFactor: CGFloat\? \{[\s\S]{0,200}?return mm \/ 24/
    .test(focalSrc);
  const cropUseInCap = /focal\.mainCropFactor/.test(capCode);
  if (!cropFactorSource) {
    bad('FocalPreset.mainCropFactor 不是 `return mm / 24` —— 裁切比例必须只有这一处真源');
  } else if (!cropUseInCap) {
    bad('CaptureCapabilities 的裁切档没有用 `focal.mainCropFactor`（又写死倍数了？）');
  } else {
    ok('裁切档系数同源（mm / 24 ⇒ 35→' + (35 / 24).toFixed(4) + ' / 48→'
      + (48 / 24).toFixed(4) + '）');
  }

  // ⑫ 焦段条宽度预算（2026-09-19 加 35mm 档时新增）
  //     为什么要有：加了档位才有横向溢出风险，而**此前自检里一条焦段条宽度检查都没有**
  //     （第 5 组只管顶栏与图标行）。做法与第 5 组一致：令牌**真读**、四机型逐档复算，
  //     并把"最窄机型上的档数硬上限"也算出来 —— 免得以后有人想加到第 7 档时才发现。
  //     水平内缩来自 `CameraView` 外层 VStack 的 `.padding(.horizontal, Theme.Spacing.md)`。
  const themeSrc11 = fs.readFileSync(themeFile2, 'utf8');
  const spacingBlock = /enum Spacing \{[\s\S]*?\n    \}/.exec(themeSrc11);
  const tok11 = n => {
    const m = new RegExp('\\b' + n + '\\s*:\\s*CGFloat\\s*=\\s*([0-9.]+)').exec(themeSrc11);
    return m ? parseFloat(m[1]) : null;
  };
  const mdTok = spacingBlock ? /\bmd\s*:\s*CGFloat\s*=\s*([0-9.]+)/.exec(spacingBlock[0]) : null;
  const pillW = tok11('focalPillWidth');
  const gap = tok11('focalStripSpacing');
  const mdInset = mdTok ? parseFloat(mdTok[1]) : null;
  const outerInsetOk = /\.padding\(\.horizontal,\s*Theme\.Spacing\.md\)/.test(
    fs.readFileSync(camViewFile, 'utf8')
  );

  if (pillW === null || gap === null || mdInset === null) {
    bad('读不到 focalPillWidth / focalStripSpacing / Spacing.md（改名了？自检需要同步）');
  } else if (!outerInsetOk) {
    bad('CameraView 里找不到外层 VStack 的 `.padding(.horizontal, Theme.Spacing.md)`'
      + ' —— 焦段条的"可用宽"假设变了，宽度预算必须重算');
  } else {
    const need = mmCount * pillW + (mmCount - 1) * gap;
    const screens = [
      { name: 'iPhone 16 Pro（402）', w: 402 },
      { name: 'iPhone 16 / 15（393）', w: 393 },
      { name: 'iPhone 14（390）', w: 390 },
      { name: 'iPhone SE / mini（375）', w: 375 }
    ];
    const availMin = screens[screens.length - 1].w - 2 * mdInset;
    const maxTiers = Math.floor((availMin + gap) / (pillW + gap));
    const over = screens.filter(d => need > d.w - 2 * mdInset);
    if (over.length) {
      bad('焦段条 ' + mmCount + ' 档需 ' + need + 'pt，以下机型放不下：'
        + over.map(d => d.name + '（可用 ' + (d.w - 2 * mdInset) + 'pt）').join('、'));
    } else if (mmCount > maxTiers) {
      bad('焦段条 ' + mmCount + ' 档超过最窄机型（375）的硬上限 ' + maxTiers + ' 档'
        + '（可用 ' + availMin + 'pt ⇒ 44n + 9(n−1) ≤ ' + availMin + '）');
    } else {
      const margins = screens.map(d => (d.w - 2 * mdInset - need) / 2);
      ok('焦段条 ' + mmCount + ' 档 = ' + need + 'pt（' + pillW + '×' + mmCount + ' + ' + gap
        + '×' + (mmCount - 1) + '），四机型两侧余量 ' + margins.map(m => m.toFixed(1)).join(' / ')
        + 'pt；375 机型档数上限 ' + maxTiers);
    }
  }

  // ⑬ 35mm 档必须严格落在 24 与 48 之间，且**不跨 switchOver[0]**（2026-09-19 新增）
  //     语义：35mm 是"主摄内部的数码裁切"。若有人把比例改大到 ≥ switchOver[1]/switchOver[0]，
  //     它就会跨到长焦那颗上 —— 那一档的标签与语义就都不成立了。
  const s0 = 2.0;                                    // 真机实测 switchOver [2.000, 10.000]
  const s1 = 10.0;
  const z24 = s0;
  const z35 = s0 * (35 / 24);
  const z48 = s0 * (48 / 24);
  if (!(z24 < z35 && z35 < z48)) {
    bad('35mm 档没落在 24 与 48 之间（' + z24.toFixed(3) + ' / ' + z35.toFixed(3) + ' / '
      + z48.toFixed(3) + '）');
  } else if (!(z35 > s0 && z35 < s1)) {
    bad('35mm 档（' + z35.toFixed(3) + '）跨出了主摄那一段（应在 switchOver[0]=' + s0
      + ' 与 switchOver[1]=' + s1 + ' 之间）—— 那会变成换镜头，不再是数码裁切');
  } else {
    ok('35mm 档在 24 与 48 之间且不跨切换点（' + z35.toFixed(3) + ' ∈ (' + z24.toFixed(3)
      + ', ' + z48.toFixed(3) + ') ⊂ (' + s0 + ', ' + s1 + '））');
  }

  // ⑭ 声明式扩展字段 + **每档都要能解析出镜头角色**
  //     （2026-09-19 新增；同日按 CB 与 Mac 的反馈各修正一次）
  //     a) 字段必须存在、默认 `false`，且**必须是 `var`**：
  //        `let` 带默认值的属性**不进 memberwise 初始化器** →
  //        `FocalPreset(..., isSwiftExtension: true)` 会编译报 "extra argument"
  //        （2026-09-19 Mac 侧编译实测抓到，`[mac-fix]` 7bd53b0）；
  //        默认 `true` 则会让"所有档位都算扩展"，等于没声明；
  //     b) `isSwiftExtension: true` **只允许出现在 `FocalCatalog` 的档位构造行里**
  //        —— 防止这个标记被当成通用开关用到别处；
  //     c) **每一档都必须能在 `lensRole` 的 switch 里找到 case** —— 这是最要命的一条：
  //        新加一档却忘了配角色 → `lensRole` 返回 nil → `zoomFactor` 返回 nil →
  //        该档**永远置灰、且点不出原因**（静默的"点了没反应"，本项目明令禁止）。
  //
  // ⚠️ **本组只做"本地一致性"，不判断"标记该不该在"。**
  //    "0 个扩展"（原型已同步、标记全部去掉）是**健康状态**，不是错误。
  //    曾经这里写的是 `extDeclared < 1 → bad`（"至少要有一处"），CB 补完原型后
  //    会把健康的 0 扩展状态误判成 FAIL —— **两边自检会打架**（CB 2026-09-19 读两边自检时发现，
  //    已在副本预演里复现）。
  //    「原型有几档、Swift 多出哪几档、标记该不该在」由 `check_presets.js` 第 4 组判定 ——
  //    **只有它两边都能读**。分工写在这里，避免以后又把跨文件的断言塞回来。
  const hasExtField = /var isSwiftExtension: Bool = false/.test(focalSrc);
  const extLines = focalSrc.match(/^.*isSwiftExtension:\s*true.*$/gm) || [];
  const extMisplaced = extLines.filter(line => !/FocalPreset\(id:/.test(line)).length;
  const extDeclared = extLines.length;
  const catalogIds = (focalSrc.match(/FocalPreset\(id: "(\d+)"/g) || [])
    .map(s => /"(\d+)"/.exec(s)[1]);
  const roleLess = catalogIds.filter(id => !roleMap[id]);
  if (!hasExtField) {
    bad('FocalPreset 缺 `var isSwiftExtension: Bool = false` 字段（声明式扩展的载体；'
      + '必须是 var —— let 带默认值不进 memberwise init，传参会编译报 extra argument）');
  } else if (extMisplaced) {
    bad('有 ' + extMisplaced + ' 处 `isSwiftExtension: true` 不在 FocalCatalog 的档位构造里'
      + ' —— 这个标记只该用来标注档位');
  } else if (roleLess.length) {
    bad('这些档位在 lensRole 里没有对应角色：' + roleLess.join('、')
      + ' —— 它们会**永远置灰且点不出原因**（静默的"点了没反应"）');
  } else {
    ok('声明式扩展规范（' + (extDeclared === 0
      ? '当前 0 个扩展 —— 原型已同步'
      : extDeclared + ' 档标为 Swift 扩展')
      + '），且 ' + catalogIds.length + ' 档都能解析出镜头角色');
  }
}

/* ---------- 12. 参数刻度条（B2 · 模块 #9） ---------- */
// 为什么要这一组：
//   a) 三条刻度条**一次只显示一条** —— 必须由单值状态保证（不是三个 Bool），写错就会"三条同时露出"；
//   b) 手动档状态必须**从硬件回读**、不许本地记账 —— 否则会出现"UI 说手动、设备是自动"
//      （切模式只换 output 不换 device；而**点按对焦还会把曝光打回自动**）；
//   c) ISO 与快门**必须成对写**（`setExposureModeCustom` 一次接管两者），只写一个会被上层挡成
//      `partialManualExposure`；
//   d) 越界写硬件是**抛异常**（不是被忽略）→ 三处 clamp 一个都不能少；
//   e) **EV 与手动档互斥**是本件最容易出静默 bug 的一处（拖 EV 会把 ISO/快门 的锁定悄悄解除）；
//   f) **Backlog ④ 的正解**就在这里：`collapseOverlays()` 与 `dismissTransientPopovers()` 都要收刻度条。
console.log('\n[12] 参数刻度条 (B2)');

const b2CatFile = files.find(f => path.basename(f) === 'ParameterStripCatalog.swift');
const b2CfgFile = files.find(f => path.basename(f) === 'CaptureDeviceConfigurator.swift');
const b2SessFile = files.find(f => path.basename(f) === 'CaptureSessionController.swift');
const b2VmFile = files.find(f => path.basename(f) === 'CameraViewModel.swift');

if (!b2CatFile || !b2CfgFile || !b2SessFile || !b2VmFile) {
  bad('找不到 ParameterStripCatalog / CaptureDeviceConfigurator / CaptureSessionController / CameraViewModel');
} else {
  const catSrc12 = fs.readFileSync(b2CatFile, 'utf8');
  const cfgSrc12 = fs.readFileSync(b2CfgFile, 'utf8');
  const sessSrc12 = fs.readFileSync(b2SessFile, 'utf8');
  const vmSrc12 = fs.readFileSync(b2VmFile, 'utf8');
  const cfgCode12 = cfgSrc12.replace(/\/\/[^\n]*/g, '');

  // ① 三条刻度条：单值寄存 + 三格入口都接线
  const singleSlot = /@Published private\(set\) var paramStrip: ParameterStripKind\?/.test(vmSrc12);
  const threeEntries = ['whiteBalance', 'iso', 'shutter']
    .every(k => new RegExp('stripTapped\\(\\.' + k + '\\)').test(vmSrc12));
  const reTapSetsNil = /paramStrip = willExpand \? kind : nil/.test(vmSrc12);
  if (!singleSlot) {
    bad('`paramStrip` 不是单值寄存（应为 `ParameterStripKind?`）—— "一次只显示一条"必须由类型保证');
  } else if (!threeEntries) {
    bad('图标行三格没有都走 stripTapped（白平衡 / 感光 / 快门速度）');
  } else if (!reTapSetsNil) {
    bad('刻度条缺"再点同一条 = 收起"（应为 `paramStrip = willExpand ? kind : nil`）');
  } else {
    ok('三条刻度条单值寄存（`ParameterStripKind?`）· 三格都接 stripTapped · 再点同一条可收起');
  }

  // ② 手动档状态**从硬件回读**（不是本地记账）
  const cfgReaders = /func manualExposure\(of device: AVCaptureDevice\)[\s\S]{0,160}?exposureMode == \.custom/
      .test(cfgSrc12)
    && /func manualWhiteBalance\(of device: AVCaptureDevice\)[\s\S]{0,160}?whiteBalanceMode == \.locked/
      .test(cfgSrc12);
  const sessPublishes = /@Published private\(set\) var manualExposure:/.test(sessSrc12)
    && /@Published private\(set\) var manualWhiteBalance:/.test(sessSrc12);
  const vmDerives = /var isISOShutterAuto: Bool \{ environment\?\.session\.manualExposure == nil \}/
      .test(vmSrc12)
    && /var isWhiteBalanceAuto: Bool \{ environment\?\.session\.manualWhiteBalance == nil \}/
      .test(vmSrc12);
  if (!cfgReaders) {
    bad('configurator 缺"手动档真值回读"（`manualExposure(of:)` / `manualWhiteBalance(of:)`）'
      + ' —— 没有它 UI 只能本地记账，必然出现"UI 说手动、设备是自动"');
  } else if (!sessPublishes) {
    bad('session 没有发布 `manualExposure` / `manualWhiteBalance`（回读结果要能传到 UI）');
  } else if (!vmDerives) {
    bad('VM 的 `isISOShutterAuto` / `isWhiteBalanceAuto` 不是派生自 session 的硬件真值'
      + ' —— 本地记账 = "UI 说手动、设备是自动"（点按对焦会把曝光打回自动）');
  } else {
    ok('手动档状态从硬件回读（configurator 读 → session 发布 → VM 派生），不本地记账');
  }

  // ③ ISO 与快门**成对写**
  //
  // ⚠️ 必须**限定在 `setManualExposure` 的方法体内**：项目里还有一条**预设路径**
  //    （`applyExposureLocked`）也调 `setExposureModeCustom(duration:iso:)`，
  //    只按全文匹配的话，"手动方法里把 iso 拆掉"依然能被另一处满足 → 守卫形同虚设
  //    （2026-09-19 变异测试 M24 抓出来的：那条守卫当时是全文匹配的）。
  const manualExpBody = methodBodyOf(cfgCode12, 'setManualExposure');
  const manualWBBody = methodBodyOf(cfgCode12, 'setManualWhiteBalance');
  const pairWrite = !!manualExpBody
    && /setExposureModeCustom\(\s*duration:\s*safeDuration,\s*iso:\s*safeISO/.test(manualExpBody);
  if (!pairWrite) {
    bad('`setManualExposure` 里的 `setExposureModeCustom` 没有同时给 `duration:` 与 `iso:` —— '
      + '锁了 ISO 就得接管曝光时长，只写一个会抛 partialManualExposure'
      + '（这条是"ISO/快门 共用一个开关"的硬件根源）');
  } else {
    ok('ISO 与快门在同一次 `setExposureModeCustom(duration:iso:)` 里成对写入');
  }

  // ④ 三处 clamp（越界赋值是抛异常）—— 同样要**限定在手动方法体内**（原因同 ③）
  const clampISO = !!manualExpBody
    && /safeISO[\s\S]{0,120}?clamped\(to: format\.minISO\.\.\.format\.maxISO\)/.test(manualExpBody);
  const clampDuration = !!manualExpBody
    && /durationRange = format\.minExposureDuration\.\.\.format\.maxExposureDuration/
      .test(manualExpBody)
    && /safeDuration = requested\.clamped\(to: durationRange\)/.test(manualExpBody);
  const clampGains = !!manualWBBody
    && /normalize\(device\.deviceWhiteBalanceGains\(for: values\), for: device\)/.test(manualWBBody);
  if (!clampISO || !clampDuration || !clampGains) {
    bad('手动档三处 clamp 不全（ISO ' + clampISO + ' / 时长 ' + clampDuration
      + ' / 白平衡增益 ' + clampGains + '）—— 越界赋值是**抛异常**，不是被忽略');
  } else {
    ok('三处 clamp 齐全（ISO → minISO…maxISO / 时长 → min…maxExposureDuration / 白平衡增益 → normalize）');
  }

  // ⑤ 唯一入口（铁律 2 的延伸：硬件写入口只能在 configurator）
  const manualWriters = files
    .filter(f => /setExposureModeCustom\(|setWhiteBalanceModeLocked\(/.test(fs.readFileSync(f, 'utf8')))
    .map(f => path.basename(f));
  if (manualWriters.length !== 1 || manualWriters[0] !== 'CaptureDeviceConfigurator.swift') {
    bad('`setExposureModeCustom` / `setWhiteBalanceModeLocked` 出现在 '
      + manualWriters.join(' / ') + ' —— 硬件参数只允许走 CaptureDeviceConfigurator（铁律 2）');
  } else {
    ok('手动曝光 / 白平衡的硬件写入口只在 CaptureDeviceConfigurator（铁律 2）');
  }

  // ⑥ Backlog ④ 的两半：两处收口都要收刻度条
  const collapseBody12 = methodBodyOf(vmSrc12, 'collapseOverlays');
  const collapseHasStrip = !!collapseBody12 && /paramStrip = nil/.test(collapseBody12);
  const dismissBody12 = methodBodyOf(vmSrc12, 'dismissTransientPopovers');
  const dismissCallsStrip = !!dismissBody12 && /dismissParamStripIfNeeded\(\)/.test(dismissBody12);
  if (!collapseHasStrip) {
    bad('`collapseOverlays()` 没有收刻度条 —— 下划收不干净（Backlog ④ 只补了一半）');
  } else if (!dismissCallsStrip) {
    bad('`dismissTransientPopovers()` 没有收刻度条 —— "点别处收起"漏了它');
  } else {
    ok('刻度条已并入两处收口（collapseOverlays + dismissTransientPopovers）—— Backlog ④ 关闭');
  }

  // ⑦ EV ↔ 手动曝光档互斥（三道里至少两道要留在代码里，且 configurator 那道必须**留痕**）
  const vmEvGate = /guard !isManualExposureActive else \{[\s\S]{0,300}?return\s*\n\s*\}/.test(
    methodBodyOf(vmSrc12, 'exposureEditingChanged') || ''
  );
  const cfgSwitchWarn = /switchedBackFromManual[\s\S]{0,400}?DebugLog\.shared\.warn/.test(cfgCode12);
  const tapGuard = /isManualExposureActive[\s\S]{0,200}?showToast/.test(vmSrc12);
  if (!vmEvGate) {
    bad('VM 的 `exposureEditingChanged` 没有"手动档不推 EV"的守卫 —— 拖一下 EV 会把 '
      + 'ISO/快门 的锁定**静默解除**（`setExposureTargetBias` 在手动档下被系统忽略，'
      + '而 configurator 还会回切自动档）');
  } else if (!cfgSwitchWarn) {
    bad('configurator 的"手动档下推 EV → 回切自动"没有打 warn 留痕 —— 静默改掉别处设置，'
      + '排障时什么都看不到');
  } else if (!tapGuard) {
    bad('手动档下点「曝光补偿」没有说明原因（"点了没反应"违反产品约束）');
  } else {
    ok('EV 与手动曝光档互斥三道齐全（点入口说明 + VM 守卫 + configurator warn 留痕）');
  }

  // ⑧ 刻度条不落盘（`paramStrip` 是临时浮层状态）
  const persisted = /lumen\.camera\.strip/.test(vmSrc12) || /lumen\.camera\.strip/.test(sessSrc12);
  const stripToDefaults = /paramStrip[\s\S]{0,100}?UserDefaults/.test(vmSrc12);
  if (persisted || stripToDefaults) {
    bad('刻度条状态被落盘了（`lumen.camera.strip.*` / `paramStrip` → UserDefaults）—— '
      + '它是临时浮层状态，不该跨启动（`docs/16` 第六节）');
  } else {
    ok('刻度条状态不落盘（`paramStrip` 是临时浮层状态）');
  }

  // ⑨ 显示值：拖动期取**草稿**、其余取**硬件真值**（结构性避开 `docs/14` 那类环路）
  const displayBody12 = methodBodyOf(vmSrc12, 'stripDisplayValue');
  const usesDraft = !!displayBody12 && /isoShutterDraft|whiteBalanceDraft/.test(displayBody12);
  const usesHardware = !!displayBody12
    && /session\.manualExposure|session\.manualWhiteBalance/.test(displayBody12);
  const noMirrorState = !/@Published private\(set\) var strip(Value|Draft|Kelvin)/.test(vmSrc12);
  if (!usesDraft) {
    bad('`stripDisplayValue` 拖动期没有取草稿 —— 气泡不会跟手');
  } else if (!usesHardware) {
    bad('`stripDisplayValue` 非拖动期没有取**硬件真值** —— 那就又变成"本地值 vs 硬件值"两套，'
      + '`docs/14` 那个环路会复发');
  } else if (!noMirrorState) {
    bad('VM 里出现了一个专门镜像刻度条值的 `@Published` 状态 —— 正是 `docs/14` 环路的温床'
      + '（拖动期显示草稿、其余显示硬件真值，不需要第三个状态）');
  } else {
    ok('刻度条显示值：拖动期取草稿（跟手）+ 其余取硬件真值（无本地镜像状态，环路结构性不存在）');
  }

  // ⑥ 参数排（EV 面板）与刻度条区**同槽互斥**（`docs/16` 第四.2 节）
  //
  // 为什么必须守：两者占的是**同一行**（图标行之下）。写成两个独立 `if`，
  // 状态竞争下会**同时为真** —— 两块加起来 88 + 16 + 72 = 176pt，当场顶破净可见底线，
  // 而且"同槽"的版式语义也破了。本项目在浮层互斥上翻过车，所以这里用结构守死。
  {
    const view12 = fs.readFileSync(camViewFile, 'utf8');
    // ⚠️ 窗口要盖得住 `ExposurePanel(…)` 那一整块（含它的注释，约 1.6k 字符）——
    //    窗口太窄会**误判成"不是 else if"** 而不是"两个独立 if"，报错指不到根因
    //    （2026-09-19 变异测试 M30 第一次就撞上这个：FAIL 报了，但文案对不上）。
    const sameSlot = /if isExposurePanelShown \{[\s\S]{0,2500}?\} else if let \w+ = viewModel\.paramStrip \{[\s\S]{0,1600}?ParameterStripView\(/
      .test(view12);
    const twoIndependentIfs = /if isExposurePanelShown \{[\s\S]{0,2500}?\}\s*if let \w+ = viewModel\.paramStrip/
      .test(view12);
    const stripRendered = /ParameterStripView\(/.test(view12);
    if (!stripRendered) {
      bad('CameraView 没有渲染 ParameterStripView —— 刻度条数据层建好了但界面上出不来');
    } else if (twoIndependentIfs) {
      bad('参数排与刻度条被写成了**两个独立 if** —— 会同时展开（同槽互斥破了，净可见也破了）');
    } else if (!sameSlot) {
      bad('参数排与刻度条不是 `if … else if …` 收口的同槽互斥');
    } else {
      ok('参数排与刻度条同槽互斥（`if … else if …` 收口，不会同时展开）');
    }
  }

  // ⑩ 净可见账（B2-0 的成果 · **分母取安全区高**，用户 2026-09-19 拍板 ①）
  //
  // 算式（与 `docs/16` 第三.2 节一字不差）：
  //   底栏块 = 底内边距 + Σ行高 + 行距 × 间隙数
  //   净可见 = 安全区高 − (上内边距 + 顶栏) − 底栏块
  //   约束   = 净可见 ≥ 50% × 安全区高
  // 行高**全部从 `Theme` 真读**；EV 面板高从 `ParameterSlider` 的
  // 标题行 `minHeight` + 轨道 `thumbDiameter` + 两个间距推导（面板高是内容算出来的，没有令牌）。
  // ⚠️ 为什么必须"逐机型复算"：`docs/11` 那套旧算式（分母取整屏高 + 漏掉常驻的场景·风格条）
  // 在 844 机型上会把常态算成 50.2%（只剩 2pt 余量），口径一改结论就翻。
  {
    const themeSrcAll = fs.readFileSync(themeFile2, 'utf8');
    const tok = n => {
      const m = new RegExp('\\b' + n + '\\s*:\\s*CGFloat\\s*=\\s*([0-9.]+)').exec(themeSrcAll);
      return m ? parseFloat(m[1]) : null;
    };
    const spacingBlockAll = /enum Spacing \{[\s\S]*?\n    \}/.exec(themeSrcAll);
    const spacingTok = n => {
      if (!spacingBlockAll) return null;
      const m = new RegExp('\\b' + n + '\\s*:\\s*CGFloat\\s*=\\s*([0-9.]+)').exec(spacingBlockAll[0]);
      return m ? parseFloat(m[1]) : null;
    };

    const sliderFile = files.find(f => path.basename(f) === 'ParameterSlider.swift');
    const sliderSrcAll = sliderFile ? fs.readFileSync(sliderFile, 'utf8') : '';
    const titleRowMatch = /frame\(minWidth: 56, minHeight: ([0-9.]+)\)/.exec(sliderSrcAll);
    const thumbMatch = /thumbDiameter: CGFloat = ([0-9.]+)/.exec(sliderSrcAll);

    const gap = spacingTok('md');
    const pad = spacingTok('sm');
    const rowScene = tok('sceneStyleCollapsedHeight');
    const rowSceneOpen = tok('sceneStyleExpandedHeight');
    const rowTool = tok('toolRowHeight');
    const rowFocal = tok('focalStripHeight');
    const rowShutter = tok('shutterRowHeight');
    const rowFilter = tok('filterStripExpandedHeight');
    const rowStrip = tok('paramStripHeight');
    const topBar = tok('topBarHeight');

    const missing = Object.entries({
      gap, pad, rowScene, rowSceneOpen, rowTool, rowFocal, rowShutter, rowFilter,
      rowStrip, topBar, titleRow: titleRowMatch ? parseFloat(titleRowMatch[1]) : null,
      thumb: thumbMatch ? parseFloat(thumbMatch[1]) : null
    }).filter(([, v]) => v === null).map(([k]) => k);

    if (missing.length) {
      bad('净可见账读不到这些令牌：' + missing.join(' / ') + '（改名了？自检需要同步）');
    } else {
      const titleRow = parseFloat(titleRowMatch[1]);
      const thumb = parseFloat(thumbMatch[1]);
      // EV 面板高 = 标题行 + 间距 + 轨道 + 上下内边距；手动档多一行说明（**按一行算**）
      const evPanel = titleRow + (spacingTok('xs') || 6) + thumb + 2 * pad;

      // ⚠️ 手动档那句说明**必须短到一行**：每多一行面板就高 12pt，
      //    而 844 机型在 EV 面板态只剩 0.8pp 余量（下面这张账就是证据）。
      //    所以这里核一下它的长度（≤ 20 字）—— 改长了当场报出来。
      const panelFile = files.find(f => path.basename(f) === 'ExposurePanel.swift');
      const panelSrc = panelFile ? fs.readFileSync(panelFile, 'utf8') : '';
      const noteMatch = /Text\("(手动[^"]*)"\)/.exec(panelSrc);
      const noteText = noteMatch ? noteMatch[1] : null;
      const noteChars = noteText ? Array.from(noteText).length : 0;
      const noteOneLine = noteChars > 0 && noteChars <= 20;
      const evPanelManual = evPanel + 12;   // 多一行 10pt 文案 ≈ 12pt

      if (!noteText) {
        bad('ExposurePanel 里找不到"手动档"的说明文案（改措辞了？自检需要同步）');
      } else if (!noteOneLine) {
        bad('ExposurePanel 的手动档说明有 ' + noteChars + ' 字（> 20）—— 会折成两行、'
          + '面板高 12pt，844 机型的净可见会掉到 50% 以下');
      }
      const topBlock = pad + topBar;

      const devices = [
        { name: 'iPhone 16 Pro（874）', screen: 874, safe: 778 },
        { name: 'iPhone 16 / 15（852）', screen: 852, safe: 756 },
        { name: 'iPhone 14（844）', screen: 844, safe: 748 }
      ];
      // 每一态 = 底栏里从上到下的行高（不含底内边距与行距，下面按 rows 数自动算）
      const states = [
        { key: '常态', rows: [rowScene, rowTool, rowFocal, rowShutter], mustPass: true },
        { key: '刻度条展开', rows: [rowScene, rowTool, rowStrip, rowShutter], mustPass: true },
        { key: 'EV 面板展开（自动档）', rows: [rowScene, rowTool, evPanel, rowShutter], mustPass: true },
        { key: 'EV 面板展开（手动档）', rows: [rowScene, rowTool, evPanelManual, rowShutter], mustPass: true },
        { key: '场景·风格展开', rows: [rowSceneOpen, rowTool, rowShutter], mustPass: false },
        { key: '滤镜条展开', rows: [rowFilter, rowScene, rowTool, rowShutter], mustPass: false }
      ];

      const lines = [];
      let brokeMust = false;
      let brokeOther = [];
      for (const st of states) {
        const stack = pad + st.rows.reduce((a, b) => a + b, 0) + gap * (st.rows.length - 1);
        const percents = devices.map(d => {
          const net = d.safe - topBlock - stack;
          return net / d.safe * 100;
        });
        const worst = Math.min(...percents);
        const flag = worst >= 50 ? '' : ' ⚠️ 低于 50%';
        lines.push(st.key + ' 底栏块 ' + stack.toFixed(1) + 'pt → '
          + percents.map(p => p.toFixed(1) + '%').join(' / ') + flag);
        if (worst < 50) {
          if (st.mustPass) brokeMust = true;
          else brokeOther.push(st.key + '（最差 ' + worst.toFixed(1) + '%）');
        }
      }

      if (brokeMust) {
        bad('净可见破 50%（分母取安全区高）：' + lines.join(' ｜ '));
      } else {
        ok('净可见 ≥ 50%（分母取安全区高 · 874/852/844）：' + lines.join(' ｜ '));
      }
      if (brokeOther.length) {
        // 既有问题，**不是 FAIL** —— 但必须留痕（不做"悄悄放过"）
        console.log('  注意  这些**既有**状态仍是 < 50%（不在 B2 范围，需单独拍板）：'
          + brokeOther.join('、'));
      }
    }
  }

  // ⑮ 图标行高亮态（B2b）：`activeItem` 存在 + 展开的那一格用原型那个绿 + 旧 `isAccent` 已退场
  //
  // 为什么守：原来「曝光补偿」恒用 accent（琥珀）高亮，理由是"七项里唯一可用的参数入口"——
  // B2 之后白平衡/感光/快门都能用了，那个理由不成立。改成"**当前展开的那一格**高亮"
  // （原型 `.icon-item.active`），并且统一用原型那个绿，避免同一行里两种语义的强调色。
  {
    const toolFile = files.find(f => path.basename(f) === 'ToolIconRow.swift');
    const toolSrc = toolFile ? fs.readFileSync(toolFile, 'utf8') : '';
    const hasActive = /var activeItem: ToolIconRowItem\?/.test(toolSrc);
    const itemEnum = /enum ToolIconRowItem: String, CaseIterable \{[\s\S]{0,400}?case settings/
      .test(toolSrc);
    const usesOkGreen = /isActive \? Theme\.Palette\.ok/.test(toolSrc);
    const legacyAccent = /isAccent/.test(toolSrc);
    const a11y = /accessibilityAddTraits\(isActive \? \[\.isSelected\]/.test(toolSrc);
    const viewUsesActive = /activeItem: activeToolRowItem/.test(
      fs.readFileSync(camViewFile, 'utf8')
    );
    if (!hasActive || !itemEnum) {
      bad('ToolIconRow 缺 `activeItem` / `ToolIconRowItem` 枚举 —— 展开态没有高亮，'
        + '用户看不出"这条浮层是从哪一格开的"');
    } else if (!usesOkGreen) {
      bad('图标行的高亮没用 `Theme.Palette.ok`（原型 `.icon-item.active` 用的是绿）');
    } else if (legacyAccent) {
      bad('图标行还留着旧的 `isAccent`（"七项里唯一可用的参数入口"那个理由 B2 之后不成立）');
    } else if (!a11y) {
      bad('图标行高亮缺无障碍标记（`.isSelected` 特性）');
    } else if (!viewUsesActive) {
      bad('CameraView 没有把 `activeToolRowItem` 传给图标行 —— 高亮态永远不亮');
    } else {
      ok('图标行高亮态齐备（activeItem + 原型绿 + .isSelected 标记，旧 isAccent 已退场）');
    }
  }
}

/* ---------- 结论 ---------- */

console.log('\n' + (failed === 0 ? '全部通过：结构自检无问题' : '有 ' + failed + ' 项未通过，需要修'));
flush();
process.exit(failed === 0 ? 0 : 1);
