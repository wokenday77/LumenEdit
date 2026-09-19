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
  /* 参数排 2026-09-17 改版：常驻图标行 44px；选中参数时展开 140px（44 + 96 刻度条） */
  const H_PARAMS_ON = pick('.screen.strip-on .row-params');
  const H_PARAMS_OFF= pick('.row-params');
  const H_SS_OFF    = pick('.row-scenestyle');
  const H_SS_ON     = pick('.screen.ss-on .row-scenestyle');
  const H_FILTER_ON = pick('.screen.filter-on .row-filter');
  const H_EV_SIMPLE = pick('.screen.simple .row-ev');
  const H_FOCAL     = pick('.row-focal');
  const H_FOCAL_OFF = pick('.screen.ss-on .row-focal');
  const H_FOCAL_SIMPLE = pick('.screen.simple .row-focal');
  const H_SHUTTER_ZOOM = pick('.screen.zoom-on .row-shutter');
  const H_SS_ZOOM      = pick('.screen.zoom-on .row-scenestyle');
  const H_STATUS    = pick('.statusbar');
  const H_TOPBAR    = pick('.topbar');

  const missing = Object.entries({ H_SAFE, H_SHUTTER, H_PARAMS_ON, H_PARAMS_OFF, H_SS_OFF, H_SS_ON, H_FILTER_ON, H_EV_SIMPLE, H_FOCAL, H_FOCAL_OFF, H_FOCAL_SIMPLE, H_SHUTTER_ZOOM, H_SS_ZOOM, H_STATUS, H_TOPBAR })
    .filter(([, v]) => v === null).map(([k]) => k);
  if (missing.length) {
    bad('CSS 里读不到这些高度：' + missing.join(', '));
  } else {
    ok('各浮层高度可读：安全区 ' + H_SAFE + ' / 快门 ' + H_SHUTTER + '→' + H_SHUTTER_ZOOM + '(放大)'
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
      ['简易模式（含 EV 横滑）',   H_SAFE + H_SHUTTER + H_EV_SIMPLE + H_SS_OFF + H_FOCAL_SIMPLE],
      ['放大态（⤢，v2 卡片化）',  H_SAFE + H_SHUTTER_ZOOM + H_SS_ZOOM + H_FOCAL]
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

    /* ---- 展开态内容不得溢出其行高 ----
       这条规则是冲着"场景·风格展开后内容压在图标行上"那个 bug 来的：
       行高 144px 自身完全合格，但内容实高 147px，多出的 39px 直接盖到下面的 7 图标行上 ——
       只校验行高根本拦不住。所以这里按 CSS 里各部件的实际高度把内容实高算出来对比。
       数值全部从 CSS 读，不硬编码；读完算不出就报错，避免"悄悄不检查"。 */
    const num = (re) => { const m = css.match(re); return m ? parseFloat(m[1]) : null; };
    const SS = {
      SS_TITLE_H:  num(/\.ss-block-title\s*\{[^}]*?height:\s*([\d.]+)px/),
      SS_BLOCK_PT: num(/\.ss-block\s*\{[^}]*?padding-top:\s*([\d.]+)px/),
      SS_BLOCK_BT: num(/\.ss-block\s*\{[^}]*?border-top:\s*([\d.]+)px/),
      SS_CHIP_H:   num(/\.scene-chip\s*\{[^}]*?height:\s*([\d.]+)px/),
      SS_THUMB_H:  num(/\.style-thumb\s*\{[^}]*?height:\s*([\d.]+)px/),
      SS_BADGE_H:  num(/\.style-badge\s*\{[^}]*?height:\s*([\d.]+)px/),
      SS_NAME_FS:  num(/\.style-name\s*\{[^}]*?font-size:\s*([\d.]+)px/),
      SS_NAME_LH:  num(/\.style-name\s*\{[^}]*?line-height:\s*([\d.]+)/),
      SS_CARD_GAP: num(/\.style-card\s*\{[^}]*?gap:\s*([\d.]+)px/)
    };
    const ssMiss = Object.entries(SS).filter(([, v]) => v === null).map(([k]) => k);
    const r1 = (v) => Math.round(v * 100) / 100;
    if (ssMiss.length) {
      bad('场景·风格展开态的内容高度算不出来（CSS 里读不到）：' + ssMiss.join(', '));
    } else {
      // 风格卡 = 缩略图 + 间距 + 名称(字号×行高) + 间距 + 参数徽标
      const styleCardH = SS.SS_THUMB_H + SS.SS_CARD_GAP + SS.SS_NAME_FS * SS.SS_NAME_LH
                       + SS.SS_CARD_GAP + SS.SS_BADGE_H;
      // 展开区 = 两个块，每块 = 上边框 + 上内边距 + 块标题；块1 装场景胶囊，块2 装风格卡
      const ssContentH = 2 * (SS.SS_BLOCK_BT + SS.SS_BLOCK_PT + SS.SS_TITLE_H)
                       + SS.SS_CHIP_H + styleCardH;
      // 展开时 CSS 会把折叠胶囊隐藏（.screen.ss-on .ss-collapsed{display:none}），
      // 那时整行高度都归展开内容；若哪天不再隐藏，就得扣掉折叠条那 36px。
      const ssCapHidden = /\.screen\.ss-on\s*\.ss-collapsed\s*\{[^}]*?display:\s*none/.test(css);
      const ssAvailH = ssCapHidden ? H_SS_ON : H_SS_ON - H_SS_OFF;
      if (ssContentH > ssAvailH + 0.5) {
        bad('场景·风格展开态内容溢出 ' + r1(ssContentH - ssAvailH) + 'px：内容实高 '
          + r1(ssContentH) + 'px > 可用 ' + r1(ssAvailH) + 'px（= 行高 ' + H_SS_ON
          + (ssCapHidden ? '' : ' − 折叠条 ' + H_SS_OFF) + '），多出的部分会压在下面的图标行上');
      } else {
        ok('场景·风格展开态内容不溢出：内容实高 ' + r1(ssContentH) + 'px ≤ 可用 '
          + r1(ssAvailH) + 'px（余量 ' + r1(ssAvailH - ssContentH) + 'px）· '
          + (ssCapHidden ? '展开时折叠胶囊已隐藏，整行归内容' : '折叠条仍占 ' + H_SS_OFF + 'px'));
      }
    }

    /* ---- 圆盘态（.screen.dial-on）：模态操作，规则与常驻浮层不同 ----
       打开圆盘时底部浮层整条收起；**圆心 X + Y 一起钉在底部图标行「对焦」按钮的中心上**，
       以该点为心向四周对称展开 —— 不是"贴屏幕底往上排"。
       底线是 30% 而不是 50% —— 圆盘是模态操作，用户此时专心调焦、不需要看全取景画面；
       30% 的作用是防止"圆盘把屏幕占满"。
       参数全部从 :root / CSS 真读，不在脚本里抄第二份。 */
    const pickVar = (name) => {
      const m = css.match(new RegExp(name + '\\s*:\\s*([\\d.]+)px'));
      return m ? parseFloat(m[1]) : null;
    };
    const FD_SIZE  = pickVar('--fd-size');
    const FD_CX    = pickVar('--fd-center-x');
    const FD_CY    = pickVar('--fd-center-y');
    const FD_GAP   = pickVar('--fd-gap');
    const FD_PAD   = pickVar('--fd-pad');
    const FD_AUTO  = pickVar('--fd-auto-h');
    const SCREEN_W = 390 - 18;           // 屏内宽（外壳 390 − 左右各 9px padding）
    const pctOf    = (v) => Math.round(v / SCREEN_H * 1000) / 10;

    const fdMissing = Object.entries({ FD_SIZE, FD_CX, FD_CY, FD_GAP, FD_PAD, FD_AUTO })
      .filter(([, v]) => v === null).map(([k]) => k);
    if (fdMissing.length) {
      bad('圆盘参数读不到（:root 里少了）：' + fdMissing.join(', '));
    } else {
      // 规则 A：圆心必须对齐图标行第 2 项「对焦」按钮的中心
      //   图标行 = N 项等分 + 左右各 padding 6px → 第 2 项（index 1）中心 = pad + 项宽 × 1.5
      const padM = css.match(/\.params-closed-bar\s*\{[^}]*?padding:\s*0\s+(\d+)px/);
      const barPad = padM ? parseInt(padM[1], 10) : null;
      // 精确匹配 class="icon-item"（闭合引号）—— ⤢ 放大态的镜像按钮是 class="icon-item mirror"，
      // 不在图标行里，不能计进"7 项等分"
      const iconCount = (html.match(/class="icon-item(?! mirror")/g) || []).length;
      if (barPad === null) {
        bad('从 CSS 读不到 .params-closed-bar 的左右 padding，无法校验圆心对齐');
      } else if (iconCount !== 7) {
        bad('图标行应为 7 项，实际 ' + iconCount + ' 项 —— 圆心对齐公式依赖"7 项等分"');
      } else {
        const itemW = (SCREEN_W - barPad * 2) / iconCount;
        const btnCx = barPad + itemW * 1.5;
        if (Math.abs(FD_CX - btnCx) > 1) {
          bad('圆心 X ' + FD_CX + 'px 与「对焦」按钮中心 ' + btnCx.toFixed(1)
            + 'px 不对齐（差 ' + Math.abs(FD_CX - btnCx).toFixed(1) + 'px）');
        } else {
          ok('圆心 X 对齐「对焦」按钮：' + FD_CX + 'px ≈ 按钮中心 ' + btnCx.toFixed(1) + 'px');
        }
      }

      // 规则 E：圆心 Y 必须对齐「对焦」按钮中心的 Y
      //   按钮中心的 Y 可纯从 CSS 推导 —— 底部浮层栈自下而上是
      //   安全区 → 快门排 → 焦段条 → 图标行（图标行正好填满"参数排收起态"那 44px）。
      //   所以 按钮中心 Y = 屏高 −(安全区 + 快门 + 焦段)− 图标行高 / 2。
      //   tools/shot.js 会独立给出浏览器实测值，两边一致才说明布局真的落到了设计位置。
      const btnCy = SCREEN_H - H_SAFE - H_SHUTTER - H_FOCAL - H_PARAMS_OFF / 2;
      if (Math.abs(FD_CY - btnCy) > 1) {
        bad('圆心 Y ' + FD_CY + 'px 与「对焦」按钮中心 ' + btnCy.toFixed(1)
          + 'px 不对齐（差 ' + Math.abs(FD_CY - btnCy).toFixed(1)
          + 'px）—— 圆盘会显得和按钮是"分开的两个东西"');
      } else {
        ok('圆心 Y 对齐「对焦」按钮：' + FD_CY + 'px ≈ 按钮中心 ' + btnCy.toFixed(1)
          + 'px（屏高 ' + pctOf(btnCy) + '%）');
      }

      // 规则 B：右侧不得越界。左侧允许被裁 —— 参考图本身就不是"完整露出"
      const rightEdge = FD_CX + FD_SIZE / 2;
      const leftCut = Math.max(0, FD_SIZE / 2 - FD_CX);
      if (rightEdge > SCREEN_W) {
        bad('圆盘右缘 ' + rightEdge.toFixed(1) + 'px 超过屏内宽 ' + SCREEN_W + 'px —— 会盖到屏幕外');
      } else {
        ok('圆盘右侧不越界：右缘 ' + rightEdge.toFixed(1) + 'px ≤ ' + SCREEN_W + 'px；'
          + '左侧按参考图裁 ' + leftCut.toFixed(1) + 'px（占屏宽 '
          + Math.round(leftCut / SCREEN_W * 1000) / 10 + '%）');
      }

      // 规则 D：**圆盘组**不得越过屏幕底
      //   圆心钉在按钮上之后，先被顶出屏幕的不是圆盘，而是它下面的「自动对焦」开关行 ——
      //   所以这一条量的是"圆盘 + 间距 + 开关行"整组的下沿；只量圆盘下沿拦不住真正的故障。
      const dialTopY     = FD_CY - FD_SIZE / 2;
      const dialBottomY  = FD_CY + FD_SIZE / 2;
      const groupBottomY = dialBottomY + FD_GAP + FD_AUTO;
      if (groupBottomY > SCREEN_H) {
        bad('圆盘组下沿 ' + groupBottomY.toFixed(1) + 'px 越过屏高 ' + SCREEN_H
          + 'px —— 「自动对焦」开关行会被屏幕切掉（圆盘下沿 '
          + dialBottomY.toFixed(1) + 'px，本身还在屏内）');
      } else {
        ok('圆盘组纵向不越界：圆盘 ' + dialTopY.toFixed(1) + '..' + dialBottomY.toFixed(1)
          + 'px（下沿占屏高 ' + pctOf(dialBottomY) + '%）· 开关行下沿 '
          + groupBottomY.toFixed(1) + 'px（余量 ' + (SCREEN_H - groupBottomY).toFixed(1) + 'px）');
      }

      // 规则 C：圆盘态净可见取景面积 ≥ 30%
      const dialNet = dialTopY - TOP;
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

  // 互斥规则：展开态 setter 必须把其他几个关掉。
  // 2026-09-17 参数排改版后：参数排展开态是 state.paramStrip（layout.paramsOpen 与 setParams 已废弃），
  // EV 圆盘 layout.evOpen 也是互斥的一员。
  if (scriptMatch) {
    const code = scriptMatch[1];
    const body = (name) => {
      const i = code.indexOf('function ' + name + '(');
      if (i < 0) return null;
      const j = code.indexOf('\n  }', i);
      return code.slice(i, j);
    };
    const OTHERS = [
      ['ssExpanded',     'ssExpanded = false'],
      ['filterExpanded', 'filterExpanded = false'],
      ['paramStrip',     'state.paramStrip = null'],
      ['evOpen',         'layout.evOpen = false']
    ];
    const rules = [
      ['setSS',     'ssExpanded'],
      ['setFilter', 'filterExpanded']
    ];
    let ruleOK = true;
    rules.forEach(([fn, own]) => {
      const b = body(fn);
      if (!b) { bad('找不到函数 ' + fn); ruleOK = false; return; }
      OTHERS.filter(([k]) => k !== own).forEach(([k, needle]) => {
        if (b.indexOf(needle) < 0) {
          bad(fn + ' 没有把 ' + k + ' 关掉 —— 互斥规则不成立');
          ruleOK = false;
        }
      });
    });
    if (ruleOK) ok('互斥规则成立：展开场景/风格或滤镜条时，其他展开态（含刻度条 / EV 圆盘）全部关掉');
  }
}

/* ---------- 8. 对标参考图的元素齐备性 ---------- */
console.log('\n[8] 对标参考图的元素');
if (scriptMatch) {
  const code = scriptMatch[1];

  // 底部图标行七项：前置 / 对焦 / 白平衡 / 感光 / 快门速度 / 曝光补偿 / 设置
  // （精确闭合引号：⤢ 放大态的镜像按钮是 class="icon-item mirror"，不在本行内）
  const iconItems = (html.match(/class="icon-item(?! mirror")/g) || []).length;
  if (iconItems === 7) ok('底部图标行 = 7 项');
  else bad('底部图标行应为 7 项，实际 ' + iconItems);

  // 焦段档位 13 / 24 / 35 / 48 / 120（2026-09-19：加 35mm，与 Swift 侧 FocalCatalog 对齐）
  const fi = code.indexOf('var FOCALS = [');
  const fj = fi < 0 ? -1 : code.indexOf('\n  ];', fi);
  const focalBlock = fi < 0 ? '' : code.slice(fi, fj);
  const focalCount = (focalBlock.match(/id:\s*'/g) || []).length;
  if (focalCount === 5) ok('焦段档位 = 5（13 / 24 / 35 / 48 / 120mm）');
  else bad('焦段档位应为 5，实际 ' + focalCount);

  // 焦段条宽度预算（2026-09-19 新增）：档位一多就有溢出风险，而这条以前没人守
  // （`docs/17` 指出的原型侧盲区；Swift 侧同款检查是第 11 组 ⑫）。
  // 药丸宽 / 间距 / 条内边距**全部从 CSS 真读** —— 改尺寸这里自动跟着变，不抄第二份数。
  // 现在：5 档 = 5×44 + 4×9 = 256 ≤ 可用 344（屏内宽 372 − 2×14），余 88px。
  const fPillW = (html.match(/\.focal-pill\{[^}]*width:(\d+)px/) || [])[1];
  const fGap   = (html.match(/\.focal-strip\{[^}]*gap:(\d+)px/) || [])[1];
  const fPad   = (html.match(/\.focal-strip\{[^}]*padding:0 (\d+)px/) || [])[1];
  if (fPillW === undefined || fGap === undefined || fPad === undefined) {
    bad('读不到焦段药丸尺寸（.focal-pill 的 width / .focal-strip 的 gap、padding）—— 改名了？宽度预算要跟着改');
  } else {
    const stripW = focalCount * +fPillW + (focalCount - 1) * +fGap;
    const availW = 372 - 2 * +fPad;
    if (stripW > availW) {
      bad('焦段条放不下：' + focalCount + ' 档 = ' + focalCount + '×' + fPillW + ' + '
        + (focalCount - 1) + '×' + fGap + ' = ' + stripW + 'px > 可用 ' + availW
        + 'px（超 ' + (stripW - availW) + 'px）—— 减档 / 缩间距 / 改横向滚动，三选一');
    } else {
      ok('焦段条宽度预算：' + focalCount + ' 档 = ' + stripW + 'px ≤ 可用 ' + availW
        + 'px（余 ' + (availW - stripW) + 'px）');
    }
  }

  // 参考图里出现过的元素，都得在原型里找得到
  const need = [
    ['id="dotsL"',           'L 声道电平表'],
    ['id="dotsR"',           'R 声道电平表'],
    ['id="btnFlash"',        '闪光灯'],
    ['id="btnGrid"',         '网格'],
    ['id="btnMore"',         '功能面板入口（⠿）'],
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
  else ok('参考图元素齐备（电平表 / 闪光灯·网格·⠿面板 / 影调预览 / 存储 / 镜头切换·前置 / 风格方块 / 焦段药丸）');

  // 功能面板（对标飓风相机 ⠿）：两行 8 按钮 + 底部「简易模式」链接；
  // 旧「更多」下拉菜单必须已移除（同一个 ⠿ 不能有两个行为）。
  const fnBtns    = (html.match(/class="fn-btn/g) || []).length;
  const hasPanel  = /id="fnPanel"/.test(html);
  const hasSimple = /id="fnSimple"/.test(html);
  const moreGone  = !/class="more-menu"/.test(html) && !/id="moreMenu"/.test(html);
  const needFnIds = ['fnLive','fnRatio','fnFlash','fnTimer','fnHdr','fnSettings','fnHud','fnStage'];
  const missFn = needFnIds.filter((id) => html.indexOf('id="' + id + '"') < 0);
  if (!hasPanel || fnBtns !== 8 || !hasSimple || !moreGone || missFn.length) {
    bad('功能面板不完整：面板=' + hasPanel + '，fn-btn=' + fnBtns + '/8，简易模式链接=' + hasSimple
      + '，旧 more-menu 已移除=' + moreGone + (missFn.length ? '，缺按钮 ' + missFn.join('/') : ''));
  } else {
    ok('功能面板齐备：8 按钮（实况/画幅比/闪光灯/倒计时/高亮增益/设置/HUD/阶段标记）'
      + ' + 底部简易模式链接，旧「更多」菜单已移除');
  }

  // 格式芯片 + 选择器（视频 / Log 实况）：分辨率 3 档 + 帧率 4 档；
  // 码率表 12 个值必须都是正数 —— 剩余可录时长就是拿它算的，写错会直接算出 0 或负数。
  const fmtOpts = (html.match(/class="fmt-opt/g) || []).length;
  const hasChip = /id="fmtChip"/.test(html);
  const hasMenu = /id="fmtMenu"/.test(html);
  const br = html.match(/var FMT_BITRATE = \{([\s\S]*?)\n  \};/);
  const brVals = br ? Array.from(br[1].matchAll(/:\s*(\d+)/g), (m) => parseInt(m[1], 10)) : [];
  const brOk = !!br && brVals.length === 12 && brVals.every((v) => v > 0);
  if (!hasChip || !hasMenu || fmtOpts !== 7 || !brOk) {
    bad('格式芯片/选择器不完整：芯片=' + hasChip + '，菜单=' + hasMenu
      + '，选项=' + fmtOpts + '/7（分辨率 3 + 帧率 4），码率表=' + brOk
      + (brVals.length ? '（读到 ' + brVals.length + ' 个值）' : ''));
  } else {
    ok('格式芯片齐备：视频/Log 显芯片、选择器 3+4 档、码率表 12 值全为正（剩余可录时长用它估算）');
  }

  // 滤镜卡（对标参考 f055「标准影调」面板）：卡 = 实时取景缩略图（当前画面 + 该滤镜）+ 名字在卡下。
  // 关键是 paintPreviewInto(sw, f.id) 这根线 —— 少了它，卡片就退化成没有预览意义的色块。
  // （面板展开态的净可见 ≥50% 由上面"滤镜条展开"那条用 CSS 真读的行高自动复核，不在这里重复。）
  const liveThumb = /paintPreviewInto\(sw, f\.id\)/.test(code);
  const hasFName  = /className = 'filter-name'/.test(code);
  const swatchCss = /\.filter-swatch\{[^}]*isolation:isolate/.test(html);
  if (!liveThumb || !hasFName || !swatchCss) {
    bad('滤镜卡不完整：实时缩略图接线=' + liveThumb + '，名字元素=' + hasFName
      + '，缩略图容器隔离（isolation）=' + swatchCss);
  } else {
    ok('滤镜卡 = 实时取景缩略图（当前画面 + 该滤镜，复用渲染管线）+ 名字在卡下');
  }

  // ⤢ 放大态（v2 完全对齐飓风相机）：按钮 + 两个镜像按钮 + 隐藏/卡片化/焦段浮动规则必须都在；
  // 高度读取与放大态净可见 ≥50% 已由第 7 组的 H_SHUTTER_ZOOM / H_SS_ZOOM / states 自动复核。
  const zoomBtn    = /id="btnZoom"/.test(html);
  const zoomMirror = /id="btnFrontMirror"/.test(html) && /id="btnSettingsMirror"/.test(html);
  const zoomHide   = /\.screen\.zoom-on \.row-params\{height:0/.test(html)
                  && /\.screen\.zoom-on \.row-scenestyle\{height:0/.test(html)
                  && /\.screen\.zoom-on \.row-filter\{height:0/.test(html);
  const zoomCard   = /\.screen\.zoom-on \.viewport\{[^}]*border-radius:18px/.test(html);
  const zoomFloat  = /\.screen\.zoom-on \.row-focal\{[^}]*bottom:136px/.test(html);
  const zoomShutOk = /\.screen\.zoom-on \.row-shutter\{height:\d+px/.test(html);
  if (!zoomBtn || !zoomMirror || !zoomHide || !zoomCard || !zoomFloat || !zoomShutOk) {
    bad('放大态不完整：⤢按钮=' + zoomBtn + '，前置/设置镜像=' + zoomMirror
      + '，场景条/图标行/滤镜条隐藏=' + zoomHide + '，取景器卡片化=' + zoomCard
      + '，焦段条浮动=' + zoomFloat + '，快门排规则=' + zoomShutOk);
  } else {
    ok('放大态齐备（v2）：取景器卡片化 + 焦段条浮进卡内底边 + 场景条/图标行隐藏'
      + ' + 快门排两行结构（前置|大快门⤢|设置）');
  }

  // 圆盘「自动对焦」开关行：任何规则都不许隐藏它。
  // （2026-09-17 用户报告圆盘打开时开关行消失 —— 实测当前代码无任何规则隐藏它，
  //   此条设防：以后谁在 .dial-on/.zoom-on 等状态里误伤 .fd-auto，这里直接报。）
  const fdAutoHidden = /[^{}]*\.fd-auto[^{]*\{[^}]*(display:\s*none|visibility:\s*hidden|height:\s*0|opacity:\s*0)/.test(html);
  const fdAutoBase   = /\.fd-auto\{[^}]*height:var\(--fd-auto-h\)/.test(html);
  if (fdAutoHidden || !fdAutoBase) {
    bad('圆盘「自动对焦」开关行被隐藏：存在隐藏规则=' + fdAutoHidden + '，基础规则在=' + fdAutoBase);
  } else {
    ok('圆盘「自动对焦」开关行无任何隐藏规则（基础高度 var(--fd-auto-h) 正常）');
  }

  // 参数导入（纯文本 → 拍摄参数）：入口行 + 编辑器三件套 + 解析器骨架必须都在。
  // 别名表要求 ≥12 键（ISO/快门/EV/白平衡/色调/对焦/焦段/画幅比/闪光灯/倒计时/场景/风格/滤镜），
  // 少一个键就等于有一类参数静默失效 —— 这是最容易"悄悄少一条"的地方。
  const prRow    = /k:'preset'[^}]*label:'参数导入'/.test(html);
  const prEditor = /id="prText"/.test(html) && /id="prApply"/.test(html) && /id="prReset"/.test(html);
  const prAlias  = (html.match(/^\s{4}(iso|shutter|ev|wb|tint|focus|focal|ratio|flash|timer|scene|style|filter):\s+\[/gm) || []).length;
  const prStops  = /var ISO_STRIP = \[/.test(html) && /SHUTTER_VAL/.test(html);
  if (!prRow || !prEditor || prAlias < 12 || !prStops) {
    bad('参数导入不完整：设置页入口=' + prRow + '，编辑器三件套=' + prEditor
      + '，别名表键数=' + prAlias + '/12，档位表=' + prStops);
  } else {
    ok('参数导入齐备：设置页入口 + 编辑器（示例/导入/还原）+ 别名表 ' + prAlias + ' 键 + ISO/快门档位表');
  }

  /* 顶栏模式条居中（2026-09-17 定稿）：两侧块等宽 → 模式条盒中心 = 屏中心 186。
     三件套缺一不可：① :root 的 --tb-side-w（= 三图标自然宽 73）；② 左块（电平表）与
     右块（格式芯片；三图标组本身就是它的定义来源）都吃这个宽度；③ 模式条内容居中。
     运行时口径在 tools/shot.js「模式条居中」：照片 / 视频 偏≤1px、Log 实况 ≤10px（芯片 91 > 73 的取舍）。 */
  const tbVar    = /--tb-side-w:\s*73px/.test(html);
  const tbSides  = /\.levels\{[^}]*min-width:var\(--tb-side-w\)/.test(html)
                && /\.fmt-chip\{[^}]*min-width:var\(--tb-side-w\)/.test(html);
  const tbCenter = /\.mode-tabs\{[^}]*justify-content:center/.test(html);
  if (!tbVar || !tbSides || !tbCenter) {
    bad('模式条居中三件套不齐：--tb-side-w=' + tbVar + '，两侧块吃它=' + tbSides
      + '，内容居中=' + tbCenter);
  } else {
    ok('模式条居中三件套齐备：--tb-side-w 73px（= 三图标自然宽）+ 电平表/格式芯片同宽 + 内容居中');
  }

  // 参数排改版（2026-09-17 · 对标飓风相机）：三条刻度条 + EV 圆盘；
  // 旧四列 .pcol 必须彻底删除（不留死代码 —— 这是用户明确要求的）。
  const spDom    = /id="spScale"/.test(html) && /id="spClip"/.test(html)
                && /id="spSwitch"/.test(html) && /id="spBubble"/.test(html);
  const spThree  = /iso:\s*\{[\s\S]*?shutter:\s*\{[\s\S]*?wb:\s*\{/.test(html);
  const spShared = /auto:\s*\{[^}]*wb:true[^}]*isoShutter:true/.test(html);
  const pcolGone = !/class="pcol/.test(html) && !/\.pcol\{/.test(html) && !/\.pcol-/.test(html);

  // 两盘共用一套圆盘组件（2026-09-17 定稿）：DIALS 表 + 单份 build/render/drag；
  // **几何反向镜像**：EV 盘圆心 = calc(屏宽 − --fd-center-x)（不许硬编码 288.9px）、
  // 数值框换到盘左（right = 50% + 半径 + 8px）、指针 3 点↔9 点由 DIALS.mirror 分支给出；
  // 指针 3 点 / 9 点由 DIALS.mirror 分支给出 —— "刻度动、指针不动"的结构保证。
  const dialShared = /var DIALS = \{/.test(html)
                  && /function dialBuild\(/.test(html) && /function dialRender\(/.test(html)
                  && /function dialFromPoint\(/.test(html);
  // EV 盘圆心必须是**镜像式**：calc(372px − --fd-center-x) —— 对焦盘中线以后要挪，EV 跟着走；
  // 同时守住 288.9px 不许硬编码（镜像关系的唯一真值在两侧圆心之和 = 372，实测里也量）。
  const evMirror   = /\.ev-wrap\{[^}]*left:calc\(372px - var\(--fd-center-x\)\)/.test(html)
                  && /\.ev-val\{[^}]*right:calc\(50% \+ var\(--fd-size\) \/ 2 \+ 8px\)/.test(html)
                  && !/288\.9px/.test(html);
  // mirror 参数 + 两个分支函数：角度映射 180±180v、指针角 270/90、环旋转 = 指针角 − 角度映射
  const dialMirror = /mirror:false/.test(html) && /mirror:true/.test(html)
                  && /cfg\.mirror \? 180 \+ v \* 180/.test(html)
                  && /cfg\.mirror \? 270 : 90/.test(html)
                  && /fdPointerDeg\(cfg\) - fdAngle\(cfg, v\)/.test(html);
  const ringFixed  = /ring:'fdRing'/.test(html) && /ring:'evRing'/.test(html);
  const evDial     = /id="evDial"/.test(html) && /id="evVal"/.test(html);

  if (!spDom || !spThree || !spShared || !evDial || !pcolGone
      || !dialShared || !ringFixed || !evMirror || !dialMirror) {
    bad('参数排/圆盘改版不完整：刻度条 DOM=' + spDom + '，三条数据=' + spThree
      + '，ISO/快门共用状态=' + spShared + '，EV 盘元素=' + evDial
      + '，旧 .pcol 已删=' + pcolGone + '，两盘共用组件=' + dialShared
      + '，EV 镜像几何=' + evMirror + '（圆心式 / 数值框盘左 / 无 288.9 硬编码）'
      + '，mirror 分支=' + dialMirror + '，两盘 ring id=' + ringFixed);
  } else {
    ok('参数排齐备：三条刻度条（固定指针 + 气泡 + 自动/手动）'
      + ' · 两个圆盘共用一套组件、互为反向镜像（EV 圆心 = 屏宽 − --fd-center-x，'
      + '数值框盘左、指针 9 点、弧左半圈）· 旧四列已彻底删除');
  }
}

/* ---------- 结论 ---------- */
console.log('\n' + (failed === 0
  ? '全部通过：' + file + ' 可以双击打开'
  : '有 ' + failed + ' 项未通过，需要修'));
flushReport();
process.exit(failed === 0 ? 0 : 1);
