#!/usr/bin/env node
/**
 * 预设数据一致性自检：Swift 端 ⟷ 网页原型
 *
 * ## 为什么需要它
 * FILTERS / STYLES / SCENES 这套数据是「单一真源、多处复用」：
 * 原型 JS、iOS 渲染参数、缩略图、预设分享都从它派生。
 * 改了一边忘另一边，要等真机渲染出来才会发现色偏 —— 那时候排查成本极高。
 *
 * 本机**不能编译 Swift**，所以这个脚本用「解析源码」的方式做交叉验证：
 *   - 原型侧：把 index.html 里的 JS 数组 eval 出来（纯数据，无副作用）
 *   - Swift 侧：正则切块 + 提字段（结构化写法，正则够用）
 * 两边都归一成同一种形状再逐项比对。
 *
 * ## 检查项
 *   1. 三张表的 id 列表与顺序
 *   2. 数量
 *   3. 每条滤镜 / 风格的色彩参数（contrast / saturate / brightness / sepia / hueRotate / grayscale）
 *   4. 叠层 tints 的背景表达式与混合模式
 *   5. 滤镜色块 swatches
 *   6. 场景的 style / filter / ev / wb
 *   7. 焦段档位
 *
 * 用法：node tools/check_presets.js [项目根目录]
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = process.argv[2] || path.resolve(__dirname, '..');
const HTML = path.join(ROOT, 'prototype', 'index.html');
const PRESET_DIR = path.join(ROOT, 'LumenEdit', 'Presets');

let failed = 0;
const failures = [];
function ok(msg) { console.log('  OK   ' + msg); }
function warn(msg) { console.log('  WARN ' + msg); }

/**
 * **软失败作用域**（2026-09-21 批六新增）：非 null 时，本组内的 FAIL 降级为 WARN。
 *
 * 用途只有一个：`ParameterStripCatalog.isSwiftAheadOfPrototype == true`（Swift 先行 + 标记，
 * 用户 2026-09-21 拍板的 ① 路由）。原型归 CB 改（WB 端只读不写），所以当 Swift 侧按新口径
 * （复刻飓风）先落地时，本组不该把整条链路卡红 —— 但**也绝不能静默放过**：
 * 降级的同时会把逐条差异原样打印出来当 CB 的待办清单。
 * CB 同步完原型、把标记改回 `false` 之后，本组**自动**恢复 FAIL 强度（不需要再改检查）。
 */
let softenGroup = null;
function bad(msg) {
  if (softenGroup) { warn('[待 CB 同步原型 · ' + softenGroup + '] ' + msg); return; }
  failed++; failures.push(msg); console.log('  FAIL ' + msg);
}

/* ============================================================
   一、从原型 index.html 里取出三个 JS 数组
   ============================================================ */

const html = fs.readFileSync(HTML, 'utf8');

function extractJsArray(varName) {
  const re = new RegExp('var\\s+' + varName + '\\s*=\\s*(\\[[\\s\\S]*?\\n  \\]);', 'm');
  const m = html.match(re);
  if (!m) return null;
  // 纯数据字面量，eval 是安全的
  return new Function('return ' + m[1])();
}

const jsFilters = extractJsArray('FILTERS');
const jsStyles  = extractJsArray('STYLES');
const jsScenes  = extractJsArray('SCENES');
const jsFocals  = extractJsArray('FOCALS');

/* ============================================================
   二、解析 Swift 源（切块 + 提字段）
   ============================================================ */

function readSwift(name) {
  return fs.readFileSync(path.join(PRESET_DIR, name), 'utf8');
}

/** 按 `Marker(` 切块，返回每个块的源码片段 */
function sliceBlocks(src, marker) {
  const parts = src.split(new RegExp('(?=' + marker + '\\()'));
  return parts.slice(1);
}

/** 取第一个匹配的字符串字面量 */
function str(block, key) {
  const m = block.match(new RegExp(key + '\\s*:\\s*"([^"]*)"'));
  return m ? m[1] : null;
}

/** 取第一个匹配的数值字面量 */
function num(block, key) {
  const m = block.match(new RegExp(key + '\\s*:\\s*(-?[0-9.]+)'));
  return m ? parseFloat(m[1]) : null;
}

/** 解析 ColorGrade(...) 里的参数；缺省值按 Swift 里的声明取 */
function parseGrade(block) {
  const m = block.match(/ColorGrade\(([^)]*)\)/);
  const g = { contrast: 1, saturate: 1, brightness: 1, sepia: 0, hueRotate: 0, grayscale: 0 };
  if (!m) return g;
  m[1].split(',').forEach(pair => {
    const kv = pair.split(':').map(s => s.trim());
    if (kv.length === 2 && kv[0] in g) g[kv[0]] = parseFloat(kv[1]);
  });
  return g;
}

/** 解析 CSS filter 表达式里的数值（原型侧），归一成和上面同形状 */
function parseCssFilter(css) {
  const g = { contrast: 1, saturate: 1, brightness: 1, sepia: 0, hueRotate: 0, grayscale: 0 };
  if (!css) return g;
  const grab = (fn) => {
    const m = css.match(new RegExp(fn + '\\((-?[0-9.]+)'));
    return m ? parseFloat(m[1]) : null;
  };
  const c = grab('contrast');       if (c !== null) g.contrast = c;
  const s = grab('saturate');       if (s !== null) g.saturate = s;
  const b = grab('brightness');     if (b !== null) g.brightness = b;
  const sp = grab('sepia');         if (sp !== null) g.sepia = sp;
  const h = grab('hue-rotate');     if (h !== null) g.hueRotate = h;
  const gr = grab('grayscale');     if (gr !== null) g.grayscale = gr;
  return g;
}

/** 叠层归一：把 CSS 背景字符串压成可比形式（去空格、统一 0 写成 0） */
function normTints(list) {
  if (!list) return [];
  return list.map(t => ({
    kind: t.kind || (String(t.b).indexOf('gradient') >= 0 ? 'gradient' : 'solid'),
    b: String(t.b).replace(/\s+/g, ' ').trim(),
    m: t.m
  }));
}

/** 解析 Swift 的 tints 调用。
 *
 *  ⚠️ 不能简单用 /\.solid\(([\s\S]*?)\)/ —— `RGBAColor(r:…, a:…)` **自带括号**，
 *  非贪婪正则会停在第一个 `)` 上，把实参截断（本轮就踩了这个坑：全部 tints 解析成空）。
 *  改用**括号深度计数**取完整实参。
 */
function parseSwiftTints(block) {
  const found = [];
  ['solid', 'linearGradient'].forEach(name => {
    const marker = '.' + name + '(';
    let i = 0;
    while ((i = block.indexOf(marker, i)) !== -1) {
      let depth = 1;
      let j = i + marker.length;
      while (j < block.length && depth > 0) {
        const ch = block[j];
        if (ch === '(') depth++;
        else if (ch === ')') depth--;
        j++;
      }
      found.push({ name, body: block.slice(i + marker.length, j - 1), at: i });
      i = j;
    }
  });
  found.sort((a, b) => a.at - b.at);   // 保持源码里的先后顺序

  const out = [];
  found.forEach(c => {
    const body = c.body;
    const blendRaw = (body.match(/blend:\s*\.(\w+)/) || [])[1];
    const blend = blendRaw === 'softLight' ? 'soft-light' : blendRaw;

    if (c.name === 'solid') {
      const m = body.match(/RGBAColor\(r:\s*(\d+),\s*g:\s*(\d+),\s*b:\s*(\d+),\s*a:\s*([0-9.]+)\)/);
      if (m) {
        out.push({
          kind: 'solid',
          b: `rgba(${m[1]}, ${m[2]}, ${m[3]}, ${trimNum(m[4])})`,
          m: blend
        });
      }
      return;
    }

    // linearGradient：角度 + 色标
    const angleM = body.match(/angleDeg:\s*(-?[0-9.]+)/);
    const angle = angleM ? parseFloat(angleM[1]) : 0;
    const angleCss = angle === 0 ? 'to top' : angle === 180 ? 'to bottom' : trimNum(angle) + 'deg';

    const stops = [];
    const sre = /RGBAColor\(r:\s*(\d+),\s*g:\s*(\d+),\s*b:\s*(\d+),\s*a:\s*([0-9.]+)\)\s*,\s*position:\s*([0-9.]+)/g;
    let s;
    while ((s = sre.exec(body)) !== null) {
      stops.push(`rgba(${s[1]}, ${s[2]}, ${s[3]}, ${trimNum(s[4])}) ${trimNum(s[5])}%`);
    }
    out.push({
      kind: 'gradient',
      b: `linear-gradient(${angleCss}, ${stops.join(', ')})`,
      m: blend
    });
  });
  return out;
}

/** alpha 归一：`.10` / `0.10` / `.1` / `0.1` 全部化成 `.1` */
function normAlpha(s) {
  let v = String(s);
  if (v.indexOf('.') >= 0) {
    v = v.replace(/0+$/, '').replace(/\.$/, '');   // 去尾零
    if (v.indexOf('0.') === 0) v = v.slice(1);      // 去前导 0 → .1
    if (v === '' || v === '0') v = '0';
  }
  return v;
}

/** 归一化 tints 的完整表达式（把两边的写法抹平后再比）。
 *  ⚠️ 两边的写法差异很大，归一化必须同时覆盖四种：
 *     原型  `rgba(255,236,200,.10)`            —— 逗号后无空格、alpha 带尾零
 *     Swift `rgba(255, 236, 200, 0.1)`         —— 逗号后有空格、alpha 去尾零
 *     渐变位置：原型首个/末个色标**省略** `0%` / `100%`，Swift 侧显式写出
 *  只按一边写规则会漏掉另一边，比对永远不相等（本轮踩了两次）。
 */
function canonTint(t) {
  let b = String(t.b).replace(/\s+/g, ' ').trim();
  b = b.replace(/rgba\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*([0-9.]+)\s*\)/g,
        (_, r, g, bl, a) => `rgba(${r}, ${g}, ${bl}, ${normAlpha(a)})`);
  // 渐变的 0% / 100% 是可省略的默认值，抹掉再比
  b = b.replace(/\s+(?:0|100)%/g, '');
  return { kind: t.kind, b, m: t.m };
}

function trimNum(v) {
  const f = parseFloat(v);
  return f === Math.round(f) ? String(Math.round(f)) : String(f);
}

/* ============================================================
   三、逐项比对
   ============================================================ */

console.log('检查源：');
console.log('  原型   ' + path.relative(ROOT, HTML));
console.log('  Swift  ' + path.relative(ROOT, PRESET_DIR));
console.log('');

/* --- 3.1 滤镜 --- */

console.log('[1] 滤镜表 FILTERS ⟷ FilterCatalog');

const swiftFilterSrc = readSwift('FilterCatalog.swift');
const swfBlocks = sliceBlocks(swiftFilterSrc, 'FilterDefinition');
const swf = swfBlocks.map(b => ({
  id: str(b, 'id'),
  name: str(b, 'displayName'),
  ref: str(b, 'reference'),
  intensity: str(b, 'intensity'),
  grade: parseGrade(b),
  tints: parseSwiftTints(b),
  sw: (b.match(/swatches:\s*\[([^\]]*)\]/) || [])[1] ? (b.match(/swatches:\s*\[([^\]]*)\]/)[1].match(/"#\w{6}"/g) || []).map(s => s.replace(/"/g, '')) : []
})).filter(x => x.id);

if (!jsFilters) bad('原型里找不到 FILTERS 数组');
else if (swf.length !== jsFilters.length) bad(`数量不一致：原型 ${jsFilters.length} 个，Swift ${swf.length} 个`);
else {
  ok(`数量一致（${jsFilters.length} 个）`);

  const jsIds = jsFilters.map(f => f.id);
  const swIds = swf.map(f => f.id);
  if (jsIds.join(',') !== swIds.join(',')) {
    bad('id 列表或顺序不一致\n      原型: ' + jsIds.join(',') + '\n      Swift: ' + swIds.join(','));
  } else {
    ok('id 列表与顺序一致');
  }

  let gradeBad = 0, tintBad = 0, swBad = 0, nameBad = 0;
  jsFilters.forEach((jf, i) => {
    const sf = swf[i];
    if (!sf) return;

    if (jf.name !== sf.name) { nameBad++; bad(`[${jf.id}] name 不一致：原型「${jf.name}」 vs Swift「${sf.name}」`); }

    const jg = parseCssFilter(jf.css);
    const keys = ['contrast', 'saturate', 'brightness', 'sepia', 'hueRotate', 'grayscale'];
    const diff = keys.filter(k => Math.abs((jg[k] || 0) - (sf.grade[k] || 0)) > 1e-9);
    if (diff.length) {
      gradeBad++;
      bad(`[${jf.id}] 参数不一致 ${diff.map(k => `${k}: 原型 ${jg[k]} vs Swift ${sf.grade[k]}`).join('; ')}`);
    }

    const jt = normTints(jf.tints).map(canonTint);
    const st = sf.tints.map(canonTint);
    if (JSON.stringify(jt) !== JSON.stringify(st)) {
      tintBad++;
      bad(`[${jf.id}] tints 不一致\n      原型 : ${JSON.stringify(jt)}\n      Swift: ${JSON.stringify(st)}`);
    }

    const jsw = (jf.sw || []).join(',');
    if (jsw !== sf.sw.join(',')) {
      swBad++;
      bad(`[${jf.id}] swatches 不一致：原型 [${jsw}] vs Swift [${sf.sw.join(',')}]`);
    }
  });
  if (!gradeBad) ok('全部滤镜的色彩参数一致');
  if (!tintBad)  ok('全部滤镜的叠层一致');
  if (!swBad)    ok('全部滤镜的色块一致');
  if (!nameBad)  ok('全部滤镜的显示名一致');
}

/* --- 3.2 风格 --- */

console.log('\n[2] 风格表 STYLES ⟷ StyleCatalog');

const swiftStyleSrc = readSwift('StylePreset.swift');
const swsBlocks = sliceBlocks(swiftStyleSrc, 'StylePreset');
const sws = swsBlocks.map(b => ({
  id: str(b, 'id'),
  name: str(b, 'displayName'),
  ref: str(b, 'reference'),
  badge: str(b, 'badge'),
  grade: parseGrade(b),
  tints: parseSwiftTints(b),
  filterId: (b.match(/filterId:\s*"([^"]*)"/) || [])[1] || null,
  fi: str(b, 'filterIntensity')
})).filter(x => x.id);

if (!jsStyles) bad('原型里找不到 STYLES 数组');
else if (sws.length !== jsStyles.length) bad(`数量不一致：原型 ${jsStyles.length} 个，Swift ${sws.length} 个`);
else {
  ok(`数量一致（${jsStyles.length} 个）`);

  const jsIds = jsStyles.map(s => s.id);
  const swIds = sws.map(s => s.id);
  if (jsIds.join(',') !== swIds.join(',')) {
    bad('id 列表或顺序不一致\n      原型: ' + jsIds.join(',') + '\n      Swift: ' + swIds.join(','));
  } else {
    ok('id 列表与顺序一致');
  }

  let gradeBad = 0, tintBad = 0, refBad = 0, badgeBad = 0;
  jsStyles.forEach((js, i) => {
    const ss = sws[i];
    if (!ss) return;

    if (js.name !== ss.name) bad(`[${js.id}] name 不一致：原型「${js.name}」 vs Swift「${ss.name}」`);

    // 原型用 filter:'f_xxx' / filter:null
    const jFilter = js.filter || null;
    if (jFilter !== ss.filterId) {
      bad(`[${js.id}] 引用的滤镜不一致：原型 ${jFilter} vs Swift ${ss.filterId}`);
      refBad++;
    }
    // 强度：原型是字符串 '0.75'
    const jFi = js.fi === undefined ? null : String(js.fi);
    if (jFi !== null && ss.fi !== null && parseFloat(jFi) !== parseFloat(ss.fi)) {
      bad(`[${js.id}] 滤镜强度不一致：原型 ${jFi} vs Swift ${ss.fi}`);
      refBad++;
    }

    const jg = parseCssFilter(js.css);
    const keys = ['contrast', 'saturate', 'brightness', 'sepia', 'hueRotate', 'grayscale'];
    const diff = keys.filter(k => Math.abs((jg[k] || 0) - (ss.grade[k] || 0)) > 1e-9);
    if (diff.length) {
      gradeBad++;
      bad(`[${js.id}] 参数不一致 ${diff.map(k => `${k}: 原型 ${jg[k]} vs Swift ${ss.grade[k]}`).join('; ')}`);
    }

    const jt = normTints(js.tints).map(canonTint);
    const st = ss.tints.map(canonTint);
    if (JSON.stringify(jt) !== JSON.stringify(st)) {
      tintBad++;
      bad(`[${js.id}] tints 不一致\n      原型 : ${JSON.stringify(jt)}\n      Swift: ${JSON.stringify(ss.tints)}`);
    }

    if (js.badge !== ss.badge) {
      badgeBad++;
      bad(`[${js.id}] badge 不一致：原型「${js.badge}」 vs Swift「${ss.badge}」`);
    }
  });
  if (!gradeBad) ok('全部风格的色彩参数一致');
  if (!tintBad)  ok('全部风格的叠层一致');
  if (!refBad)   ok('全部风格的滤镜引用与强度一致');
  if (!badgeBad) ok('全部风格的徽标文案一致');
}

/* --- 3.3 场景 --- */

console.log('\n[3] 场景表 SCENES ⟷ SceneCatalog');

const swiftSceneSrc = readSwift('ScenePreset.swift');
const swsSceneBlocks = sliceBlocks(swiftSceneSrc, 'ScenePreset');
const swScenes = swsSceneBlocks.map(b => ({
  id: str(b, 'id'),
  name: str(b, 'displayName'),
  styleId: (b.match(/styleId:\s*"([^"]*)"/) || [])[1] || null,
  filterId: (b.match(/filterId:\s*"([^"]*)"/) || [])[1] || null,
  ev: num(b, 'exposureBias'),
  wb: num(b, 'whiteBalanceKelvin')
})).filter(x => x.id);

if (!jsScenes) bad('原型里找不到 SCENES 数组');
else if (swScenes.length !== jsScenes.length) bad(`数量不一致：原型 ${jsScenes.length} 个，Swift ${swScenes.length} 个`);
else {
  ok(`数量一致（${jsScenes.length} 个）`);

  let bad3 = 0;
  jsScenes.forEach((js, i) => {
    const ss = swScenes[i];
    if (!ss) return;
    if (js.id !== ss.id) { bad(`第 ${i + 1} 项 id 不一致：原型 ${js.id} vs Swift ${ss.id}`); bad3++; return; }
    if (js.name !== ss.name) { bad(`[${js.id}] name 不一致`); bad3++; }

    const jStyle = js.style || null;
    const jFilter = js.filter || null;
    if (jStyle !== ss.styleId)  { bad(`[${js.id}] style 不一致：原型 ${jStyle} vs Swift ${ss.styleId}`); bad3++; }
    if (jFilter !== ss.filterId){ bad(`[${js.id}] filter 不一致：原型 ${jFilter} vs Swift ${ss.filterId}`); bad3++; }

    if (Math.abs((js.ev || 0) - (ss.ev || 0)) > 1e-9) {
      bad(`[${js.id}] ev 不一致：原型 ${js.ev} vs Swift ${ss.ev}`); bad3++;
    }
    const jwb = parseFloat(String(js.wb).replace(/[^\d.]/g, ''));
    if (jwb !== ss.wb) { bad(`[${js.id}] 色温不一致：原型 ${js.wb} vs Swift ${ss.wb}`); bad3++; }
  });
  if (!bad3) ok('全部场景的推荐组合、EV、色温一致');
}

/* --- 3.4 焦段 --- */

console.log('\n[4] 焦段表 FOCALS ⟷ FocalCatalog');

const swiftFocalSrc = readSwift('FocalPreset.swift');
const swFocals = sliceBlocks(swiftFocalSrc, 'FocalPreset').map(b => ({
  id: str(b, 'id'),
  name: str(b, 'displayName'),
  on: /isDefault:\s*true/.test(b),
  // 声明式扩展标记（2026-09-19 用户拍板 · 方案 `docs/17` 第八节）。
  // ⚠️ 匹配要求带 `: true`，**不能只匹配字段名** —— 档位之间的注释里会出现
  //    "必须显式标 isSwiftExtension" 这类说明文字，只匹配名字就会被注释绊倒
  //    （同类坑本项目踩过：负向判据命中注释）。
  ext: /isSwiftExtension:\s*true/.test(b)
})).filter(x => x.id);

if (!jsFocals) {
  bad('原型里找不到 FOCALS 数组');
} else {
  // 口径：**原型必须是 Swift 的"子序列"** ——
  //   ① 原型里的档位都要在 Swift 里、顺序一致，id / 显示名 / 默认标记逐项一致，
  //      且这些档位**不得**标 `isSwiftExtension`；
  //   ② Swift 多出来的档位（原型还没有）**必须显式标** `isSwiftExtension: true`，否则 FAIL；
  //   ③ 两边一致之后（CB 补完原型 + 去掉标记），本组会**自动**要求完全一致 —— 不需要再改检查。
  //
  // 为什么用这套（而不是简单放宽或一律严格）：
  //   把"原型没同步"从一个**看不见的差异**，变成**每次自检都会打印、且必须显式声明**的状态；
  //   既不会被静默放过（谁随手加一档都会 FAIL），也不会因为"等原型"而阻塞 Swift。
  const pending = swFocals.filter(f => !jsFocals.some(j => j.id === f.id));
  const missing = jsFocals.filter(j => !swFocals.some(f => f.id === j.id));
  const wronglyMarked = swFocals.filter(f => f.ext && jsFocals.some(j => j.id === f.id));

  if (missing.length) {
    bad('原型里有的档位在 Swift 里缺失：' + missing.map(j => j.id).join('、'));
  } else if (pending.some(f => !f.ext)) {
    bad('Swift 多出的档位没标 `isSwiftExtension: true`：'
      + pending.filter(f => !f.ext).map(f => f.id).join('、')
      + ' —— 先行扩展必须显式声明，否则就是静默漂移');
  } else if (wronglyMarked.length) {
    bad('这些档位原型里已经有了，却还标着 `isSwiftExtension: true`：'
      + wronglyMarked.map(f => f.id).join('、')
      + ' —— 请去掉标记，否则本组会一直对它放宽');
  } else {
    let badF = 0;
    jsFocals.forEach(jf => {
      const sf = swFocals.find(f => f.id === jf.id);
      if (!sf) return;
      if (jf.name !== sf.name) { bad(`[${jf.id}] 显示名不一致`); badF++; }
      const jOn = jf.on === true;
      if (jOn !== sf.on) { bad(`[${jf.id}] 默认选中标记不一致：原型 ${jOn} vs Swift ${sf.on}`); badF++; }
    });
    // 顺序：原型各档在 Swift 里的下标必须严格递增（档位是"从左到右"的版式，顺序即语义）
    const idx = jsFocals.map(j => swFocals.findIndex(f => f.id === j.id));
    const ordered = idx.every((v, i) => i === 0 || v > idx[i - 1]);
    if (!badF && !ordered) {
      bad('档位顺序不一致：原型 ' + jsFocals.map(j => j.id).join('/')
        + '，它们在 Swift 里的下标是 ' + idx.join('/'));
      badF++;
    }
    if (!badF) {
      ok(`原型 ${jsFocals.length} 档逐项一致（id / 显示名 / 默认标记 / 顺序）`);
    }
    if (pending.length) {
      console.log('  WARN 原型尚未同步以下档位（Swift 侧已声明为扩展）：'
        + pending.map(f => f.id).join('、')
        + ' —— CB 往 FOCALS 补上后，去掉 FocalPreset 上的 isSwiftExtension 即可，本组会自动收紧');
    } else {
      ok('两边档位完全一致（无先行扩展）');
    }
  }
}

/* --- 3.5 视频格式码率表（#11） --- */

console.log('\n[5] 码率表 FMT_BITRATE ⟷ VideoFormatCatalog');

// 原型侧：`var FMT_BITRATE = { '720p': {24:9, ...}, ... };`（对象，不是数组）
// —— 所以不能用 `extractJsArray`，单独提取并用 `new Function` 求值（内容是我们自己的原型字面量）
const bitrateLiteral = /var FMT_BITRATE = (\{[\s\S]*?\n  \});/.exec(html);
let jsBitrate = null;
if (bitrateLiteral) {
  try {
    jsBitrate = new Function('return ' + bitrateLiteral[1])();
  } catch (e) {
    bad('原型 FMT_BITRATE 解析失败：' + e.message);
  }
} else {
  bad('原型里找不到 FMT_BITRATE');
}

// Swift 侧：`.p720: [.fps24: 9, ...]` → 归一成 `{ '720p': { 24: 9, ... } }`
const swiftFmtSrc = readSwift('VideoFormatCatalog.swift');
const resMap = { p720: '720p', p1080: '1080p', uhd4K: '4K' };
const tableBlock = /bitrateTable[\s\S]*?\n    \]/.exec(swiftFmtSrc);
const swBitrate = {};
if (!tableBlock) {
  bad('VideoFormatCatalog.swift 里找不到 bitrateTable');
} else {
  const rowRe = /\.(p720|p1080|uhd4K):\s*\[([^\]]+)\]/g;
  let row;
  while ((row = rowRe.exec(tableBlock[0]))) {
    const resKey = resMap[row[1]];
    const pairs = row[2].match(/\.fps(\d+):\s*([0-9.]+)/g) || [];
    swBitrate[resKey] = {};
    pairs.forEach(p => {
      const m = /\.fps(\d+):\s*([0-9.]+)/.exec(p);
      swBitrate[resKey][m[1]] = parseFloat(m[2]);
    });
  }
}

if (jsBitrate && Object.keys(swBitrate).length) {
  let badB = 0;
  let compared = 0;
  const jsResKeys = Object.keys(jsBitrate);
  const swResKeys = Object.keys(swBitrate);
  const missingRes = jsResKeys.filter(k => !swResKeys.includes(k));
  const extraRes = swResKeys.filter(k => !jsResKeys.includes(k));
  if (missingRes.length || extraRes.length) {
    bad(`分辨率键不一致：原型缺 [${extraRes.join(', ')}]，Swift 缺 [${missingRes.join(', ')}]`);
    badB++;
  } else {
    jsResKeys.forEach(res => {
      const jsFps = Object.keys(jsBitrate[res]).sort((a, b) => +a - +b);
      const swFps = Object.keys(swBitrate[res]).sort((a, b) => +a - +b);
      if (jsFps.join(',') !== swFps.join(',')) {
        bad(`[${res}] 帧率键不一致：原型 [${jsFps.join(',')}] vs Swift [${swFps.join(',')}]`);
        badB++;
        return;
      }
      jsFps.forEach(fps => {
        compared++;
        const jv = jsBitrate[res][fps];
        const sv = swBitrate[res][fps];
        if (Math.abs(jv - sv) > 0.001) {
          bad(`[${res} ${fps}fps] 码率不一致：原型 ${jv} vs Swift ${sv}`);
          badB++;
        }
      });
    });
  }
  if (!badB) {
    ok(`码率表逐条一致（${jsResKeys.length} 分辨率 × 帧率 = ${compared} 个值）`);
  }
}

/* --- 3.6 参数刻度条（B2 · 模块 #9） --- */

console.log('\n[6] 参数刻度条 ISO_STRIP / SHUTTER_* / WB_STRIP ⟷ ParameterStripCatalog');

const stripSrc = readSwift('ParameterStripCatalog.swift');

// ── Swift 先行 + 标记（2026-09-21 批六 · 复刻飓风 = 方案 A，用户拍板路由）──────────────
// 标记在 `ParameterStripCatalog.isSwiftAheadOfPrototype`：
//   true  = Swift 先按飓风口径落地，原型待 CB 同步 → **本组降级为 WARN** 并打印差异清单；
//   false = 两边应当逐条全等（本组收紧为 FAIL）。
// 为什么需要它：原型 `prototype/index.html` 归 CB 改（WB 端只读不写），而 ① 是
// **重建级**改动（档距 46/56/26 → 统一 40、档位表、标签口径全变），不给出口就只能两边互相卡。
const swiftAheadSpec = /isSwiftAheadOfPrototype:\s*Bool\s*=\s*true/.test(stripSrc);
const swiftAheadVersion = (/specVersion:\s*String\s*=\s*"([^"]+)"/.exec(stripSrc) || [])[1] || '（未标版本）';
if (swiftAheadSpec) {
  softenGroup = '批六 ' + swiftAheadVersion;
  warn('ParameterStripCatalog 标了 `isSwiftAheadOfPrototype = true`（' + swiftAheadVersion + '）');
  warn('→ 本组**降级为 WARN**（不卡红），但差异会逐条打印出来 —— 那就是 CB 的待办清单');
  warn('→ CB 同步完原型后，把该标记改回 `false`，本组会自动收紧为"逐条全等"');
  console.log('');
}

/** 等差数列（含端点）：`seq(2500, 10000, 100)` */
function seq(start, end, step) {
  const out = [];
  for (let v = start; v <= end + 1e-9; v += step) out.push(v);
  return out;
}

/** 取 Swift 里 `name: [Double] = [ ... ]`（支持 `1.0 / 125` 这种分数写法） */
function swiftNumbers(name) {
  const m = new RegExp(name + '\\s*:\\s*\\[Double\\]\\s*=\\s*\\[([\\s\\S]*?)\\]').exec(stripSrc);
  if (!m) return null;
  return m[1].split(',')
    .map(s => s.trim())
    .filter(s => s.length > 0)
    .map(s => {
      const frac = /^([0-9.]+)\s*\/\s*([0-9.]+)$/.exec(s);
      return frac ? parseFloat(frac[1]) / parseFloat(frac[2]) : parseFloat(s);
    });
}

/** 取 Swift 里 `name: [String] = [ "a", "b" ]` */
function swiftStrings(name) {
  const m = new RegExp(name + '\\s*:\\s*\\[String\\]\\s*=\\s*\\[([\\s\\S]*?)\\]').exec(stripSrc);
  if (!m) return null;
  return Array.from(m[1].matchAll(/"([^"]*)"/g)).map(x => x[1]);
}

/** 取 Swift 里 `name: Set<Double> = [...]` 或 `= Set(stride(from:through:by:))` */
function swiftNumberSet(name) {
  const lit = new RegExp(name + '\\s*:\\s*Set<Double>\\s*=\\s*\\[([^\\]]*)\\]').exec(stripSrc);
  if (lit) {
    return lit[1].split(',').map(s => parseFloat(s.trim())).filter(n => !Number.isNaN(n));
  }
  const strided = new RegExp(
    name + '\\s*:\\s*Set<Double>\\s*=\\s*Set\\(stride\\(from: (\\d+), through: (\\d+), by: (\\d+)\\)'
  ).exec(stripSrc);
  return strided ? seq(+strided[1], +strided[2], +strided[3]) : null;
}

/** 数值数组逐项比对 */
function compareNumbers(label, js, sw) {
  if (!js || !sw) {
    bad(label + '：取不到数据（原型 ' + Boolean(js) + ' / Swift ' + Boolean(sw) + '）');
    return;
  }
  if (js.length !== sw.length) {
    bad(label + '：档数不一致（原型 ' + js.length + ' / Swift ' + sw.length + '）');
    return;
  }
  const diff = [];
  js.forEach((v, i) => {
    if (Math.abs(Number(v) - Number(sw[i])) > 1e-9) diff.push(i + ': ' + v + ' ≠ ' + sw[i]);
  });
  if (diff.length) {
    bad(label + '：有 ' + diff.length + ' 项不一致（' + diff.slice(0, 5).join('、') + '…）');
  } else {
    ok(label + '：' + js.length + ' 档逐项一致');
  }
}

/** 字符串数组逐项比对 */
function compareStrings(label, js, sw) {
  if (!js || !sw) {
    bad(label + '：取不到数据（原型 ' + Boolean(js) + ' / Swift ' + Boolean(sw) + '）');
    return;
  }
  const diff = [];
  const n = Math.max(js.length, sw.length);
  for (let i = 0; i < n; i++) {
    if (String(js[i]) !== String(sw[i])) diff.push(i + ': ' + js[i] + ' ≠ ' + sw[i]);
  }
  if (js.length !== sw.length) {
    bad(label + '：档数不一致（原型 ' + js.length + ' / Swift ' + sw.length + '）');
  } else if (diff.length) {
    bad(label + '：有 ' + diff.length + ' 项不一致（' + diff.slice(0, 5).join('、') + '…）');
  } else {
    ok(label + '：' + js.length + ' 档逐项一致');
  }
}

/**
 * 取原型里的 JS 数组字面量（**单行 / 多行都能取**）。
 *
 * 为什么不能直接用 `extractJsArray`：那个的正则要求数组以 `\n  ];`（两空格缩进的收尾）结束，
 * 也就是**只认多行数组**（FOCALS / FILTERS 那种）。而参数刻度条的
 * `ISO_STRIP` / `SHUTTER_VAL` / `SHUTTER_LABEL` 在原型里都是**单行**的，
 * 用它会静默取不到（返回 null）—— 2026-09-19 第一版就这么踩了一次。
 */
function jsArray(varName) {
  const m = new RegExp('var\\s+' + varName + '\\s*=\\s*(\\[[\\s\\S]*?\\]);', 'm').exec(html);
  if (!m) return null;
  try {
    return new Function('return ' + m[1])();   // 纯数据字面量，含 `1/2` 这类表达式也能求值
  } catch (e) {
    return null;
  }
}

// ① ISO：25 档数值
compareNumbers('ISO 档位值', jsArray('ISO_STRIP'), swiftNumbers('isoValues'));

// ② 快门：15 档秒数 + 15 档标签
compareNumbers('快门档位（秒数）', jsArray('SHUTTER_VAL'), swiftNumbers('shutterSecondValues'));
compareStrings('快门档位（标签）', jsArray('SHUTTER_LABEL'), swiftStrings('shutterLabels'));

// ③ 白平衡：原型里是**生成**的（`for k=2500;k<=10000;k+=100`），不是字面量数组 → 按生成规则比对
const jsWBRule = /WB_STRIP[\s\S]{0,80}?for \(var k=(\d+);k<=(\d+);k\+=(\d+)\)/.exec(html);
const swWBRule = /\(0\.\.\.(\d+)\)\.map \{ (\d+) \+ Double\(\$0\) \* (\d+) \}/.exec(stripSrc);
compareNumbers(
  '白平衡档位（生成规则 2500→10000 步长 100）',
  jsWBRule ? seq(+jsWBRule[1], +jsWBRule[2], +jsWBRule[3]) : null,
  swWBRule ? seq(+swWBRule[2], +swWBRule[2] + +swWBRule[1] * +swWBRule[3], +swWBRule[3]) : null
);

// ④ 可视步进 slot（三条各不相同：46 / 56 / 26）
{
  const jsSlot = k => {
    const m = new RegExp(k + ':\\s*\\{[^}]{0,200}?slot:(\\d+)').exec(html);
    return m ? parseFloat(m[1]) : null;
  };
  const swSlot = k => {
    const m = new RegExp('case \\.' + k + ':\\s*return (\\d+)').exec(stripSrc);
    return m ? parseFloat(m[1]) : null;
  };
  const kinds = [['iso', 'iso'], ['shutter', 'shutter'], ['wb', 'whiteBalance']];
  const wrong = kinds
    .filter(([jsKey, swKey]) => jsSlot(jsKey) !== swSlot(swKey))
    .map(([jsKey, swKey]) => jsKey + '：原型 ' + jsSlot(jsKey) + ' vs Swift ' + swSlot(swKey));
  if (wrong.length) {
    bad('可视步进 slot 不一致（' + wrong.join('；') + '）—— 三条档数差 5 倍，步进错会让某条长得离谱');
  } else {
    ok('可视步进 slot 一致（iso 46 / shutter 56 / wb 26）');
  }
}

// ⑤ 标签档 & 白平衡预设档
{
  // ⚠️ 批六：原型的 **`labelAt`（只给主档出数字）整套退场** —— 飓风口径是"每档都带标签"，
  //    所以 Swift 侧不再有 `isoLabelledValues` / `whiteBalanceLabelledValues` 两张表。
  //    在"Swift 先行"期间，这两条没有可比对象（原型还是旧口径）→ 给待办，不报 FAIL。
  if (softenGroup) {
    warn('[待 CB 同步原型 · ' + softenGroup + '] 原型的 `labelAt`（只标主档）机制已退场 → '
      + 'CB 需把 ISO / 快门 / 白平衡三条都改成"**每档都带标签**"（飓风做法）');
  } else {
    const jsISOLabel = /iso:\s*\{[\s\S]{0,220}?labelAt:\[([0-9,]+)\]/.exec(html);
    compareNumbers(
      'ISO 标签档',
      jsISOLabel ? jsISOLabel[1].split(',').map(Number) : null,
      swiftNumberSet('isoLabelledValues')
    );

    const jsWBLabelled = /labelAt:\(function\(\)\{ var a=\[\]; for \(var k=(\d+);k<=(\d+);k\+=(\d+)\)/
      .exec(html);
    compareNumbers(
      '白平衡标签档（每 500K）',
      jsWBLabelled ? seq(+jsWBLabelled[1], +jsWBLabelled[2], +jsWBLabelled[3]) : null,
      swiftNumberSet('whiteBalanceLabelledValues')
    );
  }

  // 预设档（琥珀刻度）**保留** —— 飓风口径不取消"预设位"语义，这条两边都必须有
  const jsWBPreset = /preset:\[([0-9,]+)\]/.exec(html);
  compareNumbers(
    '白平衡预设档',
    jsWBPreset ? jsWBPreset[1].split(',').map(Number) : null,
    swiftNumberSet('whiteBalancePresetValues')
  );
}

// ⑥ 默认档位（原型 `seed`）
{
  const jsSeedISO = /iso:\s*\{[\s\S]{0,200}?seed:(\d+)/.exec(html);
  const jsSeedShutter = /shutter:\s*\{[\s\S]{0,200}?seed:'([^']+)'/.exec(html);
  const jsSeedWB = /wb:\s*\{[\s\S]{0,200}?seed:'([^']+)'/.exec(html);
  const swISO = /defaultISO: Double = (\d+)/.exec(stripSrc);
  const swShutter = /defaultShutterSeconds: Double = ([0-9.]+) \/ ([0-9.]+)/.exec(stripSrc);
  const swWB = /defaultWhiteBalanceKelvin: Double = (\d+)/.exec(stripSrc);

  const problems = [];
  if (!jsSeedISO || !swISO || Number(jsSeedISO[1]) !== Number(swISO[1])) problems.push('ISO');
  const jsShutterDen = jsSeedShutter ? Number(jsSeedShutter[1].split('/')[1]) : null;
  const swShutterDen = swShutter ? Number(swShutter[2]) : null;
  if (jsShutterDen === null || swShutterDen === null || jsShutterDen !== swShutterDen) {
    problems.push('快门');
  }
  if (!jsSeedWB || !swWB || Number(jsSeedWB[1].replace('K', '')) !== Number(swWB[1])) {
    problems.push('白平衡');
  }
  if (problems.length) {
    bad('默认档位不一致：' + problems.join('、') + '（原型 seed vs Swift 的 default* 常量）');
  } else {
    ok('默认档位一致（ISO 800 / 快门 1/125 / 白平衡 5600K）');
  }
}

// 第 6 组结束 → **关掉软失败作用域**，别影响后面的组（软失败只服务"Swift 先行"这一段）
softenGroup = null;

/* ============================================================
   结论
   ============================================================ */

console.log('');
if (failed === 0) {
  if (swiftAheadSpec) {
    // ⚠️ 不能自称"逐条一致" —— 第 6 组现在处于"Swift 先行"状态，差异在上面的 WARN 清单里
    console.log('全部通过（**但第 6 组是"Swift 先行"状态**：'
      + swiftAheadVersion + ' —— 原型待 CB 同步，见上方 WARN 清单）');
    console.log('  原型同步完 → 把 ParameterStripCatalog.isSwiftAheadOfPrototype 改回 false，'
      + '本脚本会自动收紧为逐条全等。');
  } else {
    console.log('全部通过：Swift 预设数据与网页原型逐条一致');
  }
  process.exit(0);
} else {
  console.log(`有 ${failed} 项不一致，需要修：`);
  failures.forEach(f => console.log('  · ' + f));
  console.log('\n提示：FILTERS / STYLES / SCENES 是「单一真源、多处复用」，改一边必须同步另一边。');
  process.exit(1);
}
