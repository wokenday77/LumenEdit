/**
 * 界面原型自检脚本（Node 运行，不依赖任何第三方包）
 *
 * 我在 Windows 上没法开浏览器点，所以用这个脚本做能做的验证：
 *   1. <script> 里的 JS 语法是否合法（new Function 预编译）
 *   2. HTML 标签配平（div / button / svg）
 *   3. <style> 里的大括号是否配平
 *   4. 是否残留占位标记（形如 #XXX#）
 *   5. 数据完整性：每个 STYLES[].filter 是否都指向 FILTERS 里真实存在的 id
 *      —— 这是最容易悄悄写错、然后在界面上表现为"点了风格但滤镜条不高亮"的地方
 *   6. 内联 SVG data URI 能否生成、长度是否合理
 *
 * 用法： node tools/check_prototype.js prototype/index.html
 */

const fs = require('fs');
const path = require('path');

const file = process.argv[2] || 'prototype/index.html';
const reportPath = process.argv[3] || null;
const html = fs.readFileSync(path.resolve(file), 'utf8');

// 同时把报告写到文件：Windows 下 PowerShell 重定向会按 UTF-16 落盘导致中文乱码，
// 由 Node 自己以 UTF-8 写出最稳
const lines = [];
const rawLog = console.log.bind(console);
console.log = (...args) => { lines.push(args.join(' ')); rawLog(...args); };
function flushReport() {
  if (reportPath) {
    try { fs.writeFileSync(path.resolve(reportPath), lines.join('\n') + '\n', 'utf8'); } catch (e) { /* ignore */ }
  }
}

let failed = 0;
function ok(msg)   { console.log('  OK   ' + msg); }
function bad(msg)  { failed++; console.log('  FAIL ' + msg); }

console.log('检查文件：' + file + '（' + html.length + ' 字符）\n');

/* ---------- 1. JS 语法 ---------- */
console.log('[1] JS 语法');
const scriptMatch = html.match(/<script>([\s\S]*?)<\/script>/);
if (!scriptMatch) {
  bad('没有找到 <script> 块');
} else {
  const code = scriptMatch[1];
  try {
    new Function(code);            // 只解析不执行
    ok('JS 语法合法（' + code.length + ' 字符）');
  } catch (e) {
    bad('JS 语法错误：' + e.message);
  }
}

/* ---------- 2. HTML 标签配平 ---------- */
console.log('\n[2] HTML 标签配平');
['div', 'button', 'svg', 'span'].forEach(tag => {
  const open  = (html.match(new RegExp('<' + tag + '(?=[\\s>])', 'g')) || []).length;
  const close = (html.match(new RegExp('</' + tag + '>', 'g')) || []).length;
  if (open === close) ok(tag + ' 配平（' + open + ' 对）');
  else bad(tag + ' 不配平：开 ' + open + ' / 闭 ' + close);
});

/* ---------- 3. CSS 大括号配平 ---------- */
console.log('\n[3] CSS 大括号');
const styleMatch = html.match(/<style>([\s\S]*?)<\/style>/);
if (!styleMatch) {
  bad('没有找到 <style> 块');
} else {
  const css = styleMatch[1];
  const open  = (css.match(/{/g) || []).length;
  const close = (css.match(/}/g) || []).length;
  if (open === close) ok('大括号配平（' + open + ' 对）');
  else bad('大括号不配平：{ ' + open + ' 个 / } ' + close + ' 个');
}

/* ---------- 4. 残留占位标记 ---------- */
console.log('\n[4] 残留标记');
const markers = html.match(/<!--#[\s\S]*?#-->|#(CSS2|BODY|JS|JS2|JS3|JS4)#/g);
if (markers) bad('还有未替换的标记：' + markers.join(', '));
else ok('无残留占位标记');

/* ---------- 5. 数据完整性：风格 → 滤镜 映射 ---------- */
console.log('\n[5] 数据完整性');
if (scriptMatch) {
  const code = scriptMatch[1];

  const pickBlock = (name) => {
    const i = code.indexOf('var ' + name + ' = [');
    if (i < 0) return null;
    const j = code.indexOf('\n  ];', i);
    return code.slice(i, j);
  };

  const stylesBlock  = pickBlock('STYLES');
  const filtersBlock = pickBlock('FILTERS');
  const scenesBlock  = pickBlock('SCENES');

  if (!stylesBlock || !filtersBlock || !scenesBlock) {
    bad('无法定位数据数组（STYLES / FILTERS / SCENES）');
  } else {
    const filterIds = (filtersBlock.match(/id:\s*'([^']+)'/g) || [])
      .map(s => s.replace(/id:\s*'/, '').replace(/'$/, ''));
    const styleIds = (stylesBlock.match(/id:\s*'([^']+)'/g) || [])
      .map(s => s.replace(/id:\s*'/, '').replace(/'$/, ''));

    // 风格条目里的 filter 字段
    const styleFilterRefs = stylesBlock
      .split(/\{ id:/).slice(1)
      .map(chunk => {
        const m = chunk.match(/filter:\s*(null|'([^']+)')/);
        return m ? (m[1] === 'null' ? null : m[2]) : undefined;
      });

    console.log('    滤镜 ' + filterIds.length + ' 款，风格 ' + styleIds.length + ' 款');

    if (filterIds.length !== 14) bad('滤镜数量应为 14，实际 ' + filterIds.length);
    else ok('滤镜数量 = 14');

    if (styleIds.length !== 10) bad('风格数量应为 10，实际 ' + styleIds.length);
    else ok('风格数量 = 10');

    let refOk = true;
    styleFilterRefs.forEach((ref, i) => {
      if (ref === undefined) {
        bad('风格 #' + (i + 1) + ' 缺少 filter 字段');
        refOk = false;
      } else if (ref !== null && filterIds.indexOf(ref) < 0) {
        bad('风格 #' + (i + 1) + ' 引用了不存在的滤镜：' + ref);
        refOk = false;
      }
    });
    if (refOk) ok('所有风格的 filter 引用都指向真实存在的滤镜（或有意为 null）');

    // 场景引用检查
    const sceneFilterRefs = scenesBlock.match(/filter:\s*(null|'([^']+)')/g) || [];
    const sceneStyleRefs  = scenesBlock.match(/style:\s*(null|'([^']+)')/g) || [];
    let sceneOk = true;
    sceneFilterRefs.forEach(s => {
      const m = s.match(/'([^']+)'/);
      if (m && filterIds.indexOf(m[1]) < 0) { bad('场景引用了不存在的滤镜：' + m[1]); sceneOk = false; }
    });
    sceneStyleRefs.forEach(s => {
      const m = s.match(/'([^']+)'/);
      if (m && styleIds.indexOf(m[1]) < 0) { bad('场景引用了不存在的风格：' + m[1]); sceneOk = false; }
    });
    const sceneCount = (scenesBlock.match(/id:\s*'/g) || []).length;
    if (sceneCount !== 5) bad('场景数量应为 5，实际 ' + sceneCount);
    else if (sceneOk) ok('场景数量 = 5，且风格/滤镜引用全部有效');

    // id 唯一性
    const dupF = filterIds.filter((v, i) => filterIds.indexOf(v) !== i);
    const dupS = styleIds.filter((v, i) => styleIds.indexOf(v) !== i);
    if (dupF.length) bad('滤镜 id 重复：' + dupF.join(', ')); else ok('滤镜 id 无重复');
    if (dupS.length) bad('风格 id 重复：' + dupS.join(', ')); else ok('风格 id 无重复');

    // 每款风格/滤镜都必须有 css 与 name
    const styleNoCss = (stylesBlock.split(/\{ id:/).slice(1)).filter(c => !/css:\s*'/.test(c)).length;
    const filterNoCss = (filtersBlock.split(/\{ id:/).slice(1)).filter(c => !/css:\s*'/.test(c)).length;
    if (styleNoCss) bad(styleNoCss + ' 个风格缺少 css 字段'); else ok('所有风格都有 css 字段');
    if (filterNoCss) bad(filterNoCss + ' 个滤镜缺少 css 字段'); else ok('所有滤镜都有 css 字段');

    const filterNoSw = (filtersBlock.split(/\{ id:/).slice(1)).filter(c => !/sw:\s*\[/.test(c)).length;
    if (filterNoSw) bad(filterNoSw + ' 个滤镜缺少色块 sw 字段'); else ok('所有滤镜都有色块 sw 字段');
  }
}

/* ---------- 6. 内联 SVG data URI ---------- */
console.log('\n[6] 内联场景 SVG');
if (scriptMatch) {
  const svgMatch = scriptMatch[1].match(/var SCENE_SVG = ([\s\S]*?);\n/);
  if (!svgMatch) {
    bad('找不到 SCENE_SVG 定义');
  } else {
    // 把 + 拼接的字符串求值出来
    let svgStr = null;
    try {
      // eslint-disable-next-line no-new-func
      svgStr = new Function('return (' + svgMatch[1].replace(/;$/, '') + ')')();
    } catch (e) {
      bad('SCENE_SVG 求值失败：' + e.message);
    }
    if (typeof svgStr === 'string') {
      const encoded = encodeURIComponent(svgStr);
      if (svgStr.indexOf('<svg') === 0 && svgStr.indexOf('</svg>') > 0) {
        ok('SVG 结构完整（原始 ' + svgStr.length + ' 字符 → data URI ' + encoded.length + ' 字符）');
      } else {
        bad('SVG 首尾标签不完整');
      }
      // 未闭合的 path 数量粗查
      const pOpen = (svgStr.match(/<path /g) || []).length;
      const pSelf = (svgStr.match(/<path [^>]*\/>/g) || []).length;
      if (pOpen === pSelf) ok('所有 <path> 自闭合（' + pOpen + ' 个）');
      else bad('<path> 有 ' + (pOpen - pSelf) + ' 个未自闭合');
    }
  }
}

/* ---------- 7. 布局预算与互斥规则 ---------- */
console.log('\n[7] 布局预算与互斥规则');
if (styleMatch) {
  const css = styleMatch[1];

  // 从 CSS 里真读高度，而不是在检查脚本里再抄一遍数字 —— 改了 CSS 这里会自动跟着变
  const pick = (selector) => {
    const esc = selector.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const m = css.match(new RegExp(esc + '\\s*\\{[^}]*?height:\\s*(\\d+)px'));
    return m ? parseInt(m[1], 10) : null;
  };

  const H_SAFE      = pick('.row-safe');
  const H_SHUTTER   = pick('.row-shutter');
  const H_PARAMS_ON = pick('.row-params');
  const H_PARAMS_OFF= pick('.screen.params-closed .row-params');
  const H_SS_OFF    = pick('.row-scenestyle');
  const H_SS_ON     = pick('.screen.ss-on .row-scenestyle');
  const H_FILTER_ON = pick('.screen.filter-on .row-filter');
  const H_EV_SIMPLE = pick('.screen.simple .row-ev');
  const H_FOCAL     = pick('.row-focal');
  const H_FOCAL_OFF = pick('.screen.ss-on .row-focal');
  const H_FOCAL_SIMPLE = pick('.screen.simple .row-focal');
  const H_STATUS    = pick('.statusbar');
  const H_TOPBAR    = pick('.topbar');

  const missing = Object.entries({ H_SAFE, H_SHUTTER, H_PARAMS_ON, H_PARAMS_OFF, H_SS_OFF, H_SS_ON, H_FILTER_ON, H_EV_SIMPLE, H_FOCAL, H_FOCAL_OFF, H_FOCAL_SIMPLE, H_STATUS, H_TOPBAR })
    .filter(([, v]) => v === null).map(([k]) => k);
  if (missing.length) {
    bad('CSS 里读不到这些高度：' + missing.join(', '));
  } else {
    ok('各浮层高度可读：安全区 ' + H_SAFE + ' / 快门 ' + H_SHUTTER
      + ' / 参数 ' + H_PARAMS_ON + '→' + H_PARAMS_OFF
      + ' / 场景风格 ' + H_SS_OFF + '→' + H_SS_ON
      + ' / 滤镜 ' + H_FILTER_ON + ' / 简易EV ' + H_EV_SIMPLE
      + ' / 顶栏 ' + H_STATUS + '+' + H_TOPBAR);

    // 真机屏高 = iPhone 16 Pro 874，原型外壳 = 844 - 上下各 9px padding
    const SCREEN_H = 844 - 18;
    const TOP = H_STATUS + H_TOPBAR;   // 状态栏 + 顶部控制行（不写死，改 CSS 这里自动跟着变）

    const states = [
      ['常态（参数平铺+焦段）',    H_SAFE + H_SHUTTER + H_PARAMS_ON + H_SS_OFF + H_FOCAL],
      ['场景风格展开（焦段收起）', H_SAFE + H_SHUTTER + H_PARAMS_OFF + H_SS_ON + H_FOCAL_OFF],
      ['滤镜条展开（焦段收起）',   H_SAFE + H_SHUTTER + H_PARAMS_OFF + H_SS_OFF + H_FILTER_ON + H_FOCAL_OFF],
      ['参数收起（含焦段）',       H_SAFE + H_SHUTTER + H_PARAMS_OFF + H_SS_OFF + H_FOCAL],
      ['简易模式（含 EV 横滑）',   H_SAFE + H_SHUTTER + H_EV_SIMPLE + H_SS_OFF + H_FOCAL_SIMPLE]
    ];

    let worst = 100;
    states.forEach(([name, stack]) => {
      const net = SCREEN_H - TOP - stack;
      const pct = Math.round(net / SCREEN_H * 1000) / 10;
      if (pct < worst) worst = pct;
      console.log('    ' + name.padEnd(22, ' ') + net + 'px · ' + pct + '%');
    });

    if (worst < 50) bad('最差状态的净可见取景面积只有 ' + worst + '%，低于 50% 底线');
    else ok('所有合法状态净可见 ≥ 50%（最差 ' + worst + '%）');

    /* ---- 圆盘态（.screen.dial-on）：模态操作，规则与常驻浮层不同 ----
       打开圆盘时底部浮层整条收起，只剩「圆盘 + 间距 + 开关行 + 底部安全区」。
       底线是 30% 而不是 50% —— 圆盘是模态操作，用户此时专心调焦、不需要看全取景画面；
       30% 的作用是防止"圆盘把屏幕占满"。
       四个尺寸参数从 :root 真读，不在脚本里抄第二份。 */
    const pickVar = (name) => {
      const m = css.match(new RegExp(name + '\\s*:\\s*([\\d.]+)px'));
      return m ? parseFloat(m[1]) : null;
    };
    const FD_SIZE = pickVar('--fd-size');
    const FD_GAP  = pickVar('--fd-gap');
    const FD_PAD  = pickVar('--fd-pad');
    const FD_AUTO = pickVar('--fd-auto-h');
    const SCREEN_W = 390 - 18;          // 屏内宽（外壳 390 − 左右各 9px padding）

    const fdMissing = Object.entries({ FD_SIZE, FD_GAP, FD_PAD, FD_AUTO })
      .filter(([, v]) => v === null).map(([k]) => k);
    if (fdMissing.length) {
      bad('圆盘参数读不到（:root 里少了）：' + fdMissing.join(', '));
    } else {
      // 规则 A：圆盘必须**完整露出** —— 直径不得超过屏内宽，否则左右会被裁掉
      if (FD_SIZE > SCREEN_W) {
        bad('圆盘直径 ' + FD_SIZE + 'px 超过屏内宽 ' + SCREEN_W + 'px —— 会被裁，不满足"完整露出"');
      } else {
        ok('圆盘完整露出：直径 ' + FD_SIZE + 'px ≤ 屏内宽 ' + SCREEN_W + 'px');
      }

      // 规则 B：圆盘态净可见取景面积 ≥ 30%
      const dialStack = FD_SIZE + FD_GAP + FD_AUTO + FD_PAD;
      const dialNet = SCREEN_H - TOP - dialStack;
      const dialPct = Math.round(dialNet / SCREEN_H * 1000) / 10;
      const dialH   = Math.round(FD_SIZE / SCREEN_H * 1000) / 10;
      console.log('    ' + '圆盘打开（模态）'.padEnd(22, ' ') + dialNet + 'px · ' + dialPct + '%'
        + '   （圆盘占屏高 ' + dialH + '%）');
      if (dialPct < 30) {
        bad('圆盘打开时净可见只有 ' + dialPct + '%，低于 30% 底线（圆盘过度占屏）');
      } else {
        ok('圆盘打开时净可见 ≥ 30%（' + dialPct + '%）· 圆盘占屏高 ' + dialH + '%');
      }
    }

    // 反证：如果三个浮层允许同时展开会掉到多少 —— 这就是必须互斥的原因
    const bad372 = H_SAFE + H_SHUTTER + H_PARAMS_ON + H_SS_ON + H_FILTER_ON;
    const badPct = Math.round((SCREEN_H - TOP - bad372) / SCREEN_H * 1000) / 10;
    console.log('    违规组合（三浮层同开）→ ' + badPct + '% ← 所以必须互斥');
    if (badPct >= 50) bad('违规组合竟然也 ≥50%，互斥规则的价值需要重新评估');
  }

  // 互斥规则：三个 setter 必须把另外两个关掉
  if (scriptMatch) {
    const code = scriptMatch[1];
    const body = (name) => {
      const i = code.indexOf('function ' + name + '(');
      if (i < 0) return null;
      const j = code.indexOf('\n  }', i);
      return code.slice(i, j);
    };
    const rules = [
      ['setSS',     'ssExpanded'],
      ['setFilter', 'filterExpanded'],
      ['setParams', 'paramsOpen']
    ];
    let ruleOK = true;
    rules.forEach(([fn, own]) => {
      const b = body(fn);
      if (!b) { bad('找不到函数 ' + fn); ruleOK = false; return; }
      ['ssExpanded', 'filterExpanded', 'paramsOpen']
        .filter(f => f !== own)
        .forEach(f => {
          if (b.indexOf(f + ' = false') < 0) {
            bad(fn + ' 没有把 ' + f + ' 关掉 —— 互斥规则不成立');
            ruleOK = false;
          }
        });
    });
    if (ruleOK) ok('互斥规则成立：展开任一浮层都会关掉另外两个');
  }
}

/* ---------- 8. 对标参考图的元素齐备性 ---------- */
console.log('\n[8] 对标参考图的元素');
if (scriptMatch) {
  const code = scriptMatch[1];

  // 底部图标行七项：前置 / 对焦 / 白平衡 / 感光 / 快门速度 / 曝光补偿 / 设置
  const iconItems = (html.match(/class="icon-item/g) || []).length;
  if (iconItems === 7) ok('底部图标行 = 7 项');
  else bad('底部图标行应为 7 项，实际 ' + iconItems);

  // 焦段档位 13 / 24 / 48 / 120
  const fi = code.indexOf('var FOCALS = [');
  const fj = fi < 0 ? -1 : code.indexOf('\n  ];', fi);
  const focalBlock = fi < 0 ? '' : code.slice(fi, fj);
  const focalCount = (focalBlock.match(/id:\s*'/g) || []).length;
  if (focalCount === 4) ok('焦段档位 = 4（13 / 24 / 48 / 120mm）');
  else bad('焦段档位应为 4，实际 ' + focalCount);

  // 参考图里出现过的元素，都得在原型里找得到
  const need = [
    ['id="dotsL"',           'L 声道电平表'],
    ['id="dotsR"',           'R 声道电平表'],
    ['id="btnFlash"',        '闪光灯'],
    ['id="btnGrid"',         '网格'],
    ['id="btnMore"',         '更多'],
    ['id="btnTone"',         '影调预览'],
    ['id="chipStorage"',     '剩余存储'],
    // 镜头切换入口在 7 图标行的「前置」上；快门排那颗圆钮 2026-09-16 按用户要求移除
    // （它与「前置」功能重复，两处入口冗余）
    ['id="btnFrontCam"',      '镜头切换（前置）'],
    ['id="styleThumbInner"', '风格预览方块'],
    ['.focal-pill{',         '焦段药丸样式'],
    ['ICON_LIVE',            '「实况」Live Photo 同心圆图标']
  ];
  const miss = need.filter(([k]) => html.indexOf(k) < 0).map(([, n]) => n);
  if (miss.length) bad('缺少元素：' + miss.join('、'));
  else ok('参考图元素齐备（电平表 / 闪光灯·网格·更多 / 影调预览 / 存储 / 镜头切换·前置 / 风格方块 / 焦段药丸）');
}

/* ---------- 结论 ---------- */
console.log('\n' + (failed === 0
  ? '全部通过：' + file + ' 可以双击打开'
  : '有 ' + failed + ' 项未通过，需要修'));
flushReport();
process.exit(failed === 0 ? 0 : 1);
