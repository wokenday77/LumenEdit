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
  const mutexOK =
    // 展开场景·风格 → 收起滤镜条（toggleSceneStyle，原型 setSS）
    /func toggleSceneStyle[\s\S]{0,400}?isFilterStripExpanded\s*=\s*false/.test(vmSrc)
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


console.log('\n' + (failed === 0 ? '全部通过：结构自检无问题' : '有 ' + failed + ' 项未通过，需要修'));
flush();
process.exit(failed === 0 ? 0 : 1);
