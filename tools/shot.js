/* 原型自动截图（配合 playwright-cli 使用）

   前置：
     1) 在 prototype 目录起本地服务：
        python -m http.server 8123 --bind 127.0.0.1
     2) playwright-cli open --browser=msedge http://127.0.0.1:8123/index.html
        playwright-cli resize 430 920

   用法（项目根目录）：
     playwright-cli run-code --filename=tools/shot.js

   产物（shots/）：
     01-normal.png   常态：参数平铺 + 焦段条
     02-dial.png     对焦圆盘展开（模态）

   同时把**浏览器里真实渲染**的关键坐标打出来，用于和
   tools/check_prototype.js 里那套"从 CSS 推算"的值互相印证 ——
   两边的数一致，才说明布局真的落在了设计位置上，而不是脚本算对了、页面画错了。
*/

async page => {
  const OUT = 'D:/AI 工作存储/iPhone相机/shots/';
  const box = (sel) => page.locator(sel).boundingBox();

  // 先重载，回到默认 layout（参数排展开、圆盘关闭）。
  // 否则上一次跑完留在"圆盘已打开"的状态，这里再点一下「对焦」反而会把它关掉。
  await page.reload({ waitUntil: 'load' });
  // 清掉上次运行留下的 localStorage，保证本测从零开始（否则持久化检查会被旧数据干扰）
  await page.evaluate(() => localStorage.clear());
  await page.reload({ waitUntil: 'load' });
  await page.waitForTimeout(600);

  // ---- 常态 ----
  await page.locator('.phone').screenshot({ path: OUT + '01-normal.png' });

  // 「圆心对齐对焦按钮」要在**常态**量：圆盘打开时整条底部浮层收起（display:none），
  // 那时 #btnFocusHint 已经不可见、取不到盒 —— 这不是 bug，是"圆盘是模态"的设计。
  const btnBox = await box('#btnFocusHint').catch(() => null);

  // 参数排展开（104px）与收起（44px）是两种高度，量一下按钮的 Y 会不会跟着动 ——
  // 若会动，"圆心钉在按钮上"就得先定清楚钉在哪一种状态上。
  const btnCollapsed = await page.evaluate(() => {
    const s = document.getElementById('screen');
    const wasClosed = s.classList.contains('params-closed');
    s.classList.add('params-closed');
    const b = document.getElementById('btnFocusHint').getBoundingClientRect();
    const r = s.getBoundingClientRect();
    if (!wasClosed) s.classList.remove('params-closed');
    return { cx: b.left + b.width / 2 - r.left, cy: b.top + b.height / 2 - r.top };
  });

  // ---- 展开对焦圆盘（点底部图标行第 2 项「对焦」）----
  await page.click('#btnFocusHint');
  await page.waitForTimeout(800);
  await page.locator('.phone').screenshot({ path: OUT + '02-dial.png' });

  // ---- 量真实坐标，换算成「屏内坐标」（去掉外壳 9px 内边距）----
  const phone = await box('.phone');
  const sx = phone.x + 9;
  const sy = phone.y + 9;
  const screenW = phone.width - 18;
  const screenH = phone.height - 18;

  const r = (v) => Math.round(v * 10) / 10;
  const pct = (v) => r(v / screenH * 100) + '%';

  // 逐个元素单独取盒：任何一个量不到（display:none / 未渲染）都不许把整次截图带崩，
  // 只把它记进 missing 列表，其余照样输出 —— 这样截图永远是有的，问题也不会被吞掉。
  const probe = async (label, sel, fn) => {
    let b = null;
    try { b = await box(sel); } catch (e) { b = null; }
    if (!b) { missing.push(label + '（' + sel + '）'); return null; }
    return fn(b);
  };
  const missing = [];
  const report = {};

  report.屏 = { w: screenW, h: screenH, 壳: { w: phone.width, h: phone.height } };

  await probe('圆盘', '#focusDial', (b) => {
    report.圆盘 = {
      直径: r(b.width),
      圆心X: r(b.x + b.width / 2 - sx),
      圆心Y: r(b.y + b.height / 2 - sy),
      下沿Y: r(b.y + b.height - sy),
      左缘X: r(b.x - sx),
      圆心Y占屏高: pct(b.y + b.height / 2 - sy),
      下沿Y占屏高: pct(b.y + b.height - sy)
    };
  });

  if (btnBox) report.对焦按钮 = {
    中心X: r(btnBox.x + btnBox.width / 2 - sx),
    中心Y: r(btnBox.y + btnBox.height / 2 - sy),
    占屏高: pct(btnBox.y + btnBox.height / 2 - sy),
    尺寸: { w: r(btnBox.width), h: r(btnBox.height) },
    参数排收起时中心Y: r(btnCollapsed.cy),
    两种状态是否同位: Math.abs(btnCollapsed.cy - (btnBox.y + btnBox.height / 2 - sy)) < 1.5
  };
  else missing.push('对焦按钮（#btnFocusHint，常态未取到）');

  await probe('数值框', '.fd-val', (b) => {
    report.数值框 = { 左缘X: r(b.x - sx), 中心Y: r(b.y + b.height / 2 - sy) };
  });

  await probe('自动对焦开关行', '.fd-auto', (b) => {
    report.开关行 = { 上沿Y: r(b.y - sy), 下沿Y: r(b.y + b.height - sy) };
  });

  // 开关本体（.sw）比整行矮，量它才能确认"开关没被屏幕底切掉"——
  // 整行贴着屏底（余量 0）时，真正要盯的是这颗开关的下沿还在不在屏内。
  await probe('对焦开关本体', '.fd-auto .sw', (b) => {
    report.开关本体 = {
      上沿Y: r(b.y - sy), 下沿Y: r(b.y + b.height - sy),
      距屏底: r(screenH - (b.y + b.height - sy))
    };
  });

  await probe('取景器', '.viewport', (b) => {
    report.取景器 = { 上沿Y: r(b.y - sy), 下沿Y: r(b.y + b.height - sy) };
  });

  if (report.圆盘 && report.对焦按钮) {
    report.圆心对齐按钮 =
      Math.abs(report.圆盘.圆心X - report.对焦按钮.中心X) < 1.5 ? 'OK' : '偏差过大';
  }

  // ---- 收掉圆盘（点取景器上半区，触发 document 的"点别处关闭"）----
  const vp = await box('.viewport');
  await page.mouse.click(vp.x + vp.width * 0.5, vp.y + vp.height * 0.30);
  await page.waitForTimeout(400);

  // ---- 03 设置页：底部图标行「设置」进（功能面板取代了旧的「更多」菜单）----
  await page.click('#iconSettings');
  await page.waitForTimeout(2600);              // 等 toast（2400ms）自己消失，别挡住设置页
  await page.locator('.phone').screenshot({ path: OUT + '03-settings.png' });
  await page.click('.st-back');                 // 返回键退出设置页
  await page.waitForTimeout(400);

  // ---- 04/05 上划呼出：先滤镜条，再上划一次到场景·风格 ----
  //   手势规则：起手须在屏幕下半区（≥55% 高），且不能落在滑块/横滑条上；
  //   松手时 |dy| ≥ 34 且竖向为主、耗时 ≤ 800ms。
  //
  //   ⚠️ 必须用**合成 PointerEvent**，不能用 page.mouse 拖拽：
  //   真实鼠标拖拽在 pointerup 之后浏览器还会补一个 click，被取景器的
  //   「点按对焦 + 收起所有展开浮层」处理器吃掉 —— 刚呼出的浮层立刻被收起。
  //   下面把两种滑法都跑一遍记录 screen 的 class，作为该缺陷的现场证据。
  const screenCls = () => page.evaluate(() => document.getElementById('screen').className);

  const swipeReal = async () => {
    const x  = vp.x + vp.width * 0.72;
    const y1 = vp.y + vp.height * 0.62;
    const y2 = vp.y + vp.height * 0.30;
    await page.mouse.move(x, y1);
    await page.mouse.down();
    await page.mouse.move(x, (y1 + y2) / 2, { steps: 4 });
    await page.mouse.move(x, y2, { steps: 4 });
    await page.mouse.up();
    await page.waitForTimeout(2600);            // 等 toast 消失
  };

  const swipeSynth = async (dir) => {
    await page.evaluate((d) => {
      const s = document.getElementById('screen');
      const r = s.getBoundingClientRect();
      const x  = r.left + r.width * 0.72;
      const lo = r.top + r.height * 0.62;       // 上划起点：取景器空白处，避开底部浮层
      const hi = r.top + r.height * 0.30;       // 上划终点
      // 下划的「起点」同样必须在屏幕下半区（手势守卫要求 ≥55% 才算数），
      // 所以不能用上划的两个点反过来 —— 那样起点 30% 会被守卫直接丢弃。
      const d1 = r.top + r.height * 0.575;
      const d2 = r.top + r.height * 0.645;
      const y1 = d === 'up' ? lo : d1;
      const y2 = d === 'up' ? hi : d2;
      const fire = (type, y) => s.dispatchEvent(new PointerEvent(type, {
        bubbles: true, cancelable: true, clientX: x, clientY: y,
        pointerId: 1, pointerType: 'mouse', isPrimary: true, buttons: 1
      }));
      fire('pointerdown', y1);
      fire('pointerup', y2);
    }, dir);
    await page.waitForTimeout(2600);            // 等 toast 消失
  };

  // 证据 A：真实鼠标拖拽滑一次，看浮层有没有留下来
  //   （修复前这里会立刻被取景器 click 处理器收起 → class 里没有 filter-on）
  await swipeReal();
  report.滑动测试 = { 真实鼠标拖拽后: await screenCls() };
  await page.locator('.phone').screenshot({ path: OUT + '04-filter.png' });

  // 证据 B：先下划复位，再用合成事件逐级呼出（合成事件不产生 click，排除干扰）
  await swipeSynth('down');
  await swipeSynth('up');
  report.滑动测试.合成事件滑一次后 = await screenCls();
  await page.locator('.phone').screenshot({ path: OUT + '05-filter.png' });
  await swipeSynth('up');
  report.滑动测试.合成事件滑两次后 = await screenCls();
  await page.locator('.phone').screenshot({ path: OUT + '06-scenestyle.png' });

  // 场景·风格展开态：内容有没有撑破 144px 的行高（撑破的部分会压到下面的图标行上）
  report.场景风格展开态 = await page.evaluate(() => {
    const row = document.querySelector('.row-scenestyle');
    const rr = row.getBoundingClientRect();
    const kids = Array.from(row.children).map((el) => {
      const b = el.getBoundingClientRect();
      let deep = b.bottom - rr.top;
      el.querySelectorAll('*').forEach((c) => {
        const cb = c.getBoundingClientRect();
        if (cb.bottom - rr.top > deep) deep = cb.bottom - rr.top;
      });
      return { cls: el.className.slice(0, 28), 底: Math.round(deep) };
    });
    // 顺带量一遍底部各行的真实高度：自检是从 CSS 推算的，这里量浏览器实际值，
    // 能抓出"某条 CSS 覆盖没生效"这类推算看不见的问题（例如焦段条本该收起却没收起）。
    const rows = {};
    ['.row-filter', '.row-scenestyle', '.row-params', '.row-focal', '.row-shutter', '.row-safe']
      .forEach((sel) => {
        const el = document.querySelector(sel);
        rows[sel] = el
          ? Math.round(el.getBoundingClientRect().height) + 'px op=' + getComputedStyle(el).opacity
          : null;
      });
    return { 行高: Math.round(rr.height), 内容最深底: Math.round(Math.max(...kids.map(k => k.底))),
             子元素: kids, 底部各行实测高: rows };
  });

  // ---- 07/08 设置页收口：入口一致性 + 三个真功能开关的联动效果 ----
  //   先重载复位（前面停在"场景·风格展开态"，会干扰观察）
  await page.reload({ waitUntil: 'load' });
  await page.waitForTimeout(700);

  // B-1：底部图标行第 7 项「设置」应当打开**同一个**设置页
  await page.click('#iconSettings');
  await page.waitForTimeout(500);
  report.设置入口一致性 = {
    底部图标行设置能打开设置页:
      await page.evaluate(() => document.getElementById('settings').classList.contains('on'))
  };

  // B-3：设置 → 保留设置 二级页
  await page.click('.st-row[data-go="keep"]');
  await page.waitForTimeout(400);
  await page.locator('.phone').screenshot({ path: OUT + '07-keep-settings.png' });
  report.保留设置页标题 =
    await page.evaluate(() => document.querySelector('.settings .st-nav h2').textContent);

  // B-2：三个真功能开关 —— 预览网格关、存储空间提示关、水平指示器开
  await page.click('.st-back');
  await page.waitForTimeout(350);
  for (const label of ['预览网格', '存储空间提示', '水平指示器']) {
    await page.locator('.st-row', { hasText: label }).locator('.sw').click();
    await page.waitForTimeout(200);
  }
  await page.click('.st-back');            // 关掉设置页，回拍摄页
  await page.waitForTimeout(700);
  await page.locator('.phone').screenshot({ path: OUT + '08-switches-effect.png' });
  report.开关联动实测 = await page.evaluate(() => {
    const vis = (el) => (el ? getComputedStyle(el).display !== 'none' : null);
    return {
      screen的class: document.getElementById('screen').className,
      剩余存储胶囊可见: vis(document.querySelector('.chip-storage')),
      网格透明度: getComputedStyle(document.getElementById('grid')).opacity,
      水平线透明度: getComputedStyle(document.getElementById('levelLine')).opacity
    };
  });

  // ---- 09 影调预览：关掉 → 取景器显示原片（缩略图仍是成片） ----
  await page.reload({ waitUntil: 'load' });
  await page.waitForTimeout(700);
  const toneOnGrade = await page.evaluate(() => document.getElementById('grade').style.filter);
  await page.click('#btnTone');
  await page.waitForTimeout(500);
  const toneOffGrade = await page.evaluate(() => document.getElementById('grade').style.filter);
  await page.locator('.phone').screenshot({ path: OUT + '09-tone-off.png' });
  report.影调预览 = {
    开时取景器grade过滤: toneOnGrade,
    关时取景器grade过滤: toneOffGrade,
    关时chip仍高亮: await page.evaluate(() => document.getElementById('btnTone').classList.contains('accent'))
  };

  // ---- 10 简易模式保留项：三项全关 → 只剩取景器 + 快门 ----
  await page.click('#btnTone');                    // 影调预览开回去，免得污染持久化检查
  await page.waitForTimeout(250);
  await page.click('#iconSettings');
  await page.waitForTimeout(400);
  await page.click('[data-sw="simple"]');          // 开简易模式
  await page.waitForTimeout(250);
  await page.click('.st-row[data-go="simplemode"]');
  await page.waitForTimeout(300);
  for (const k of ['sm-thumb', 'sm-ss', 'sm-ev']) {
    await page.click('[data-sw="' + k + '"]');
    await page.waitForTimeout(150);
  }
  await page.click('.st-back');                    // 回设置主页
  await page.waitForTimeout(200);
  await page.click('.st-back');                    // 关设置页，回拍摄页
  await page.waitForTimeout(600);
  await page.locator('.phone').screenshot({ path: OUT + '10-simple-bare.png' });
  report.简易模式保留项 = await page.evaluate(() => {
    const vis = (el) => (el ? getComputedStyle(el).display !== 'none' : null);
    const h = (el) => (el ? Math.round(el.getBoundingClientRect().height) : null);
    return {
      screen的class: document.getElementById('screen').className,
      缩略图可见: vis(document.getElementById('thumb')),
      场景条高px: h(document.querySelector('.row-scenestyle')),
      EV条高px: h(document.querySelector('.row-ev'))
    };
  });

  // ---- 11 持久化：重载后上面改的状态还在（简易模式 + 三项全关） ----
  await page.waitForTimeout(600);                  // 等防抖落盘
  await page.reload({ waitUntil: 'load' });
  await page.waitForTimeout(800);
  report.持久化 = await page.evaluate(() => {
    return {
      重载后screen的class: document.getElementById('screen').className,
      settings已写入: localStorage.getItem('lumenedit:settings') !== null,
      keep已写入: localStorage.getItem('lumenedit:keep') !== null,
      shoot已写入: localStorage.getItem('lumenedit:shoot') !== null
    };
  });

  // ---- 11 功能面板：HDR 开 + 画幅比 16:9（遮幅真实生效）----
  await page.reload({ waitUntil: 'load' });
  await page.waitForTimeout(700);
  await page.click('#btnMore');
  await page.waitForTimeout(500);              // 等滑入动画 + 按钮 stagger
  await page.click('#fnHdr');                  // 高亮增益开 → 圆钮转绿
  await page.click('#fnLive');                // 实况开 → 取景器角标
  await page.click('#fnRatio');                // 4:3 → 16:9 → 遮幅出现
  await page.waitForTimeout(500);              // 等黑边过渡（260ms）
  await page.locator('.phone').screenshot({ path: OUT + '11-fn-panel.png' });
  report.功能面板 = await page.evaluate(() => {
    const on = (id) => document.getElementById(id).classList.contains('on');
    const m = document.getElementById('ratioMask');
    return {
      面板开: document.getElementById('screen').classList.contains('fn-on'),
      HDR开: on('fnHdr'),
      实况开: on('fnLive'),
      画幅比: document.querySelector('#fnRatio .fn-ic').textContent,
      遮幅显示: m.classList.contains('show'),
      遮幅黑边: m.style.getPropertyValue('--rm-h'),
      实况角标显示: document.getElementById('liveBadge').classList.contains('show')
    };
  });

  // ---- 11b 画幅比遮幅的直观验证：切到 1:1（黑边 227px，一眼可见）并收起面板 ----
  await page.click('#fnRatio');                // 16:9 → 1:1
  await page.click('#btnMore');                // 收面板，别挡住遮幅
  await page.waitForTimeout(600);
  await page.locator('.phone').screenshot({ path: OUT + '11b-ratio-1-1.png' });
  report.画幅比遮幅 = await page.evaluate(() => {
    const m = document.getElementById('ratioMask');
    const bar = parseInt(m.style.getPropertyValue('--rm-h'), 10) || 0;
    return {
      当前比例: document.querySelector('#fnRatio .fn-ic').textContent,
      黑边px: bar,
      面板已收: !document.getElementById('screen').classList.contains('fn-on'),
      实况角标: document.getElementById('liveBadge').classList.contains('show')
    };
  });

  // ---- 12 视频模式：右上角格式芯片 + 剩余可录时长 ----
  await page.reload({ waitUntil: 'load' });
  await page.waitForTimeout(700);
  await page.locator('#modeTabs .mode-tab', { hasText: '视频' }).click();
  await page.waitForTimeout(500);
  await page.locator('.phone').screenshot({ path: OUT + '12-video-fmt.png' });
  report.视频格式 = await page.evaluate(() => {
    const chip = document.getElementById('fmtChip');
    return {
      芯片文字: chip.textContent,
      芯片可见: getComputedStyle(chip).display !== 'none',
      右上三图标隐藏: getComputedStyle(document.querySelector('.tb-icons')).display === 'none',
      存储文字: document.getElementById('storageText').textContent,
      时长胶囊可见: getComputedStyle(document.querySelector('.chip-storage')).display !== 'none',
      实况角标显示: document.getElementById('liveBadge').classList.contains('show')
    };
  });

  // ---- 13 格式选择器：选 1080p / 30，芯片与剩余时长跟着变 ----
  await page.click('#fmtChip');
  await page.waitForTimeout(400);
  await page.locator('#fmtMenu .fmt-opt[data-g="res"][data-v="1080p"]').click();
  await page.locator('#fmtMenu .fmt-opt[data-g="fps"][data-v="30"]').click();
  await page.waitForTimeout(300);
  await page.locator('.phone').screenshot({ path: OUT + '13-fmt-menu.png' });
  report.格式选择 = await page.evaluate(() => ({
    菜单开: document.getElementById('screen').classList.contains('fmt-on'),
    芯片文字: document.getElementById('fmtChip').textContent,
    存储文字: document.getElementById('storageText').textContent
  }));

  // ---- 14 ⤢ 放大态（v2 卡片化）：常态 vs 放大 ----
  // 前面步骤留下的持久态（简易模式 / 视频模式 / 画幅比 / 保留项开关）会把画面搅乱，
  // 这里清一次 localStorage 回到出厂常态 —— 放大态要在"标准拍摄页"上看才有意义。
  await page.evaluate(() => localStorage.clear());
  await page.reload({ waitUntil: 'load' });
  await page.waitForTimeout(700);
  await page.locator('.phone').screenshot({ path: OUT + '18-zoom-normal.png' });
  await page.click('#btnZoom');
  await page.waitForTimeout(650);              // 等卡片 inset / 高度 / transform 过渡走完
  await page.locator('.phone').screenshot({ path: OUT + '19-zoom-on.png' });
  report.放大态 = await page.evaluate(() => {
    const gs = (sel) => getComputedStyle(document.querySelector(sel));
    const rf = document.querySelector('.row-focal').getBoundingClientRect();
    const vp = document.querySelector('.viewport').getBoundingClientRect();
    const sh = document.querySelector('.shutter').getBoundingClientRect();
    const zb = document.getElementById('btnZoom').getBoundingClientRect();
    return {
      图标行高: gs('.row-params').height,
      场景条高: gs('.row-scenestyle').height,
      取景器卡片: { 左: Math.round(vp.left), 上: Math.round(vp.top),
                   下: Math.round(vp.bottom), 圆角: gs('.viewport').borderRadius },
      焦段条: { 定位: gs('.row-focal').position,
               底距卡底px: Math.round(vp.bottom - rf.bottom) },
      快门排高: gs('.row-shutter').height,
      快门渲染宽: Math.round(sh.width),
      '⤢中心X': Math.round(zb.left + zb.width / 2),
      镜像前置可见: gs('#btnFrontMirror').display !== 'none',
      镜像设置可见: gs('#btnSettingsMirror').display !== 'none',
      '⤢转绿': gs('#btnZoom').color,
      zoomOn: document.getElementById('screen').classList.contains('zoom-on')
    };
  });

  // ---- 15 参数导入：入口行 → 编辑器 → 导入后（全对会自动退回拍摄页）----
  await page.evaluate(() => localStorage.clear());
  await page.reload({ waitUntil: 'load' });
  await page.waitForTimeout(700);
  await page.click('#iconSettings');
  await page.waitForTimeout(600);
  await page.locator('.phone').screenshot({ path: OUT + '20-import-entry.png' });
  await page.click('[data-go="preset"]');
  await page.waitForTimeout(500);
  await page.locator('.phone').screenshot({ path: OUT + '21-import-editor.png' });
  await page.click('#prApply');
  await page.waitForTimeout(700);
  await page.locator('.phone').screenshot({ path: OUT + '22-import-applied.png' });
  report.参数导入 = await page.evaluate(() => {
    const onFocal = Array.from(document.querySelectorAll('.focal-pill'))
      .filter((b) => b.classList.contains('on')).map((b) => b.textContent.trim());
    return {
      设置页已关: !document.getElementById('settings').classList.contains('on'),
      焦段选中: onFocal,
      画幅比: document.querySelector('#fnRatio .fn-ic').textContent,
      遮幅黑边: document.getElementById('ratioMask').style.getPropertyValue('--rm-h'),
      EV: document.getElementById('evNum').textContent,
      圆盘值: document.querySelector('.fd-val') ? document.querySelector('.fd-val').textContent : '(未开)',
      闪光灯开: document.getElementById('fnFlash').classList.contains('on'),
      倒计时: document.querySelector('#fnTimer .fn-ic').textContent,
      toast: document.querySelector('.toast').textContent
    };
  });
  // 导入 × 刻度条的整合证据：点白平衡条 —— 导入过 5600K，应自动是「手动 5600K」（auto 被切掉）
  await page.click('#iconWB');
  await page.waitForTimeout(400);
  report.参数导入.白平衡条 = await page.evaluate(() => ({
    气泡: document.getElementById('spBubble').textContent,
    手动态: document.getElementById('screen').classList.contains('strip-manual')
  }));
  await page.click('#iconWB');     // 收回，免得影响后续步骤
  await page.waitForTimeout(300);

  // ---- 16 参数排改版：三条刻度条 + EV 圆盘（23/24/25/26）----
  await page.evaluate(() => localStorage.clear());
  await page.reload({ waitUntil: 'load' });
  await page.waitForTimeout(700);
  await page.click('#iconISO');
  await page.waitForTimeout(500);
  await page.locator('.phone').screenshot({ path: OUT + '23-strip-iso.png' });
  await page.click('#iconShutter');
  await page.waitForTimeout(500);
  await page.locator('.phone').screenshot({ path: OUT + '24-strip-shutter.png' });
  await page.click('#iconWB');
  await page.waitForTimeout(500);
  await page.locator('.phone').screenshot({ path: OUT + '25-strip-wb.png' });
  await page.click('#iconEV');
  await page.waitForTimeout(500);
  await page.locator('.phone').screenshot({ path: OUT + '26-ev-dial.png' });

  // ---- 17 同一条的自动/手动 + 拖动吸附实测（27a/27b）----
  // EV 盘现在是模态（图标行整条被收起），先点取景器空白处把它收掉，再点图标行
  await page.mouse.click(186, 300);
  await page.waitForTimeout(400);
  await page.click('#iconISO');                 // ISO 条打开
  await page.waitForTimeout(500);
  await page.locator('.phone').screenshot({ path: OUT + '27a-auto.png' });
  const autoBubble = await page.evaluate(() => document.getElementById('spBubble').textContent);
  await page.click('#spSwitch');                // 切手动
  await page.waitForTimeout(400);
  const clip = await page.locator('#spClip').boundingBox();
  const ccx = clip.x + clip.width / 2, ccy = clip.y + clip.height / 2;
  await page.mouse.move(ccx, ccy);
  await page.mouse.down();
  await page.mouse.move(ccx - 150, ccy, { steps: 10 });   // 往左拖 = 值变大
  const during = await page.evaluate(() => document.getElementById('spBubble').textContent);
  await page.mouse.up();
  await page.waitForTimeout(250);
  await page.locator('.phone').screenshot({ path: OUT + '27b-manual.png' });
  report.参数排 = {
    行高: await page.evaluate(() => getComputedStyle(document.querySelector('.row-params')).height),
    当前条: await page.evaluate(() => document.getElementById('spScale').dataset.strip || ''),
    自动态气泡: autoBubble,
    拖动中气泡: during,
    松手吸附后: await page.evaluate(() => document.getElementById('spBubble').textContent),
    ISO落盘: await page.evaluate(() => (JSON.parse(localStorage.getItem('cam_shoot_v1') || '{}').cal || {}).iso || '(键名不同，看气泡)')
  };

  // ---- 18 圆盘镜像（刻度动指针不动 + 两盘**反向镜像**）+ 快门条反转（28/29/31）----
  await page.evaluate(() => localStorage.clear());
  await page.reload({ waitUntil: 'load' });
  await page.waitForTimeout(700);
  await page.click('#btnFocusHint');                 // 对焦盘
  await page.waitForTimeout(600);
  await page.locator('.phone').screenshot({ path: OUT + '28-focus-new.png' });
  const dialProbe = () => page.evaluate(() => {
    const scr = document.getElementById('screen').getBoundingClientRect();
    const box = (id) => {
      const b = document.getElementById(id).getBoundingClientRect();
      return [Math.round(b.left - scr.left), Math.round(b.top - scr.top), Math.round(b.width)];
    };
    const ctr = (id) => {                       // 圆心 X（屏内坐标，1 位小数 —— 守恒式要精确到 0.1）
      const b = document.getElementById(id).getBoundingClientRect();
      return Math.round((b.left + b.width / 2 - scr.left) * 10) / 10;
    };
    return {
      盘: box('focusDial'), 圆心X: ctr('focusDial'),
      数值框左缘: Math.round(document.getElementById('fdVal').getBoundingClientRect().left - scr.left),
      环旋转: document.getElementById('fdRing').getAttribute('transform'),
      指针: document.getElementById('fdPointerG').getAttribute('transform'),
      值: document.getElementById('fdVal').textContent
    };
  });
  const focusRect = await dialProbe();
  // 对焦盘是模态（图标行被收起）：点取景器把它收掉，再点 EV 图标
  await page.mouse.click(186, 300);
  await page.waitForTimeout(400);
  await page.click('#iconEV');                       // EV 盘（应自动关掉对焦盘那一侧）
  await page.waitForTimeout(600);
  await page.locator('.phone').screenshot({ path: OUT + '29-ev-mirrored.png' });
  const evRect = await page.evaluate(() => {
    const scr = document.getElementById('screen').getBoundingClientRect();
    const b = document.getElementById('evDial').getBoundingClientRect();
    const v = document.getElementById('evVal').getBoundingClientRect();
    return {
      盘: [Math.round(b.left - scr.left), Math.round(b.top - scr.top), Math.round(b.width)],
      圆心X: Math.round((b.left + b.width / 2 - scr.left) * 10) / 10,
      数值框右缘: Math.round(v.right - scr.left),
      环旋转: document.getElementById('evRing').getAttribute('transform'),
      指针: document.getElementById('evPointerG').getAttribute('transform'),
      值: document.getElementById('evVal').textContent,
      对焦盘已关: !document.getElementById('screen').classList.contains('dial-on'),
      底部栈已收: getComputedStyle(document.getElementById('bottomStack')).display === 'none'
    };
  });
  /* 镜像守恒（两条，任何一边漂了都报红）：
       ① 两盘圆心 X 之和 = 屏宽 372（83.1 + 288.9）—— 圆心镜像；
       ② 对焦盘数值框左缘 214.1 + EV 盘数值框右缘 157.9 = 372 —— 数值框镜像。 */
  const cSum = Math.round((focusRect.圆心X + evRect.圆心X) * 10) / 10;
  const bSum = focusRect.数值框左缘 + evRect.数值框右缘;
  report.圆盘镜像 = {
    对焦盘: focusRect, EV盘: evRect,
    圆心守恒: focusRect.圆心X + ' + ' + evRect.圆心X + ' = ' + cSum + '（应 = 372）',
    数值框守恒: focusRect.数值框左缘 + ' + ' + evRect.数值框右缘 + ' = ' + bSum + '（应 = 372）',
    守恒通过: (Math.abs(cSum - 372) < 0.3) && (Math.abs(bSum - 372) <= 1)
  };

  /* EV 盘拖拽映射（镜像）现场验证：0 在正左、−3 在正下、+3 在正上 —— 三个基准点各拖一次看读数。
     这是"角度映射反向"最直接的证据：截图只能看出版式镜像，手感对不对必须真拖。 */
  const evC = await page.evaluate(() => {
    const b = document.getElementById('evDial').getBoundingClientRect();
    return { cx: b.left + b.width / 2, cy: b.top + b.height / 2, r: b.width / 2 };
  });
  const evAt = async (dx, dy) => {
    await page.mouse.move(evC.cx + dx, evC.cy + dy);
    await page.mouse.down();
    await page.waitForTimeout(120);
    const v = await page.evaluate(() => document.getElementById('evVal').textContent);
    await page.mouse.up();
    return v;
  };
  const r82 = evC.r * 0.82;
  report.EV盘拖拽 = {
    正下: await evAt(0, r82),        // 期望 −3.0 EV
    正左: await evAt(-r82, 0),       // 期望 +0.0 EV（镜像后 0 点挪到正左）
    正上: await evAt(0, -r82),       // 期望 +3.0 EV
    点框归零: await (async () => {    // 收尾：点数值框归零（顺带验证归零入口 + 别把 +3EV 留给后面的截图）
      await page.click('#evVal');
      await page.waitForTimeout(200);
      return page.evaluate(() => document.getElementById('evVal').textContent);
    })()
  };

  // 同样是模态：先点取景器把 EV 盘收掉，再点图标行开快门条
  await page.mouse.click(186, 300);
  await page.waitForTimeout(400);
  await page.click('#iconShutter');                  // 快门条（新顺序）
  await page.waitForTimeout(500);
  await page.locator('.phone').screenshot({ path: OUT + '31-shutter-reversed.png' });
  report.快门条 = await page.evaluate(() =>
    Array.from(document.querySelectorAll('#spScale .sp-num')).map((n) => n.textContent));

  // ---- 19 顶栏模式条居中（三态）：内容中心必须 = 屏中心 ----
  // 口径：照片 / 视频 ≤1px（两侧块等宽 --tb-side-w，内容 justify-content:center）；
  //       Log 实况放宽到 ≤10px —— 它的格式芯片「Log · 4K · 60」自然宽 91 > 73，
  //       把模式条盒推左约 9px，是为 Logo 芯片宽度做的取舍，不是 bug（用户已确认接受）。
  await page.evaluate(() => localStorage.clear());
  await page.reload({ waitUntil: 'load' });
  await page.waitForTimeout(700);
  const tbCenter = () => page.evaluate(() => {
    const scr = document.getElementById('screen').getBoundingClientRect();
    const items = Array.from(document.querySelectorAll('#modeTabs .mode-tab'));
    const f = items[0].getBoundingClientRect();
    const l = items[items.length - 1].getBoundingClientRect();
    const c = ((f.left + l.right) / 2) - scr.left;
    return { 中心X: +c.toFixed(1), 屏中心: +(scr.width / 2).toFixed(1), 偏: +(c - scr.width / 2).toFixed(1) };
  });
  const tbPhoto = await tbCenter();
  await page.locator('#modeTabs .mode-tab', { hasText: '视频' }).click();
  await page.waitForTimeout(350);
  const tbVideo = await tbCenter();
  await page.locator('#modeTabs .mode-tab', { hasText: 'Log 实况' }).click();
  await page.waitForTimeout(350);
  const tbLog = await tbCenter();
  report.模式条居中 = {
    照片: tbPhoto, 视频: tbVideo, Log实况: tbLog,
    通过: Math.abs(tbPhoto.偏) <= 1 && Math.abs(tbVideo.偏) <= 1 && Math.abs(tbLog.偏) <= 10
  };

  report.截图 = ['01-normal', '02-dial', '03-settings', '04-filter(真实鼠标·现场证据)',
                 '05-filter', '06-scenestyle', '07-keep-settings', '08-switches-effect',
                 '09-tone-off', '10-simple-bare', '11-fn-panel', '12-video-fmt', '13-fmt-menu',
                 '18-zoom-normal', '19-zoom-on',
                 '20-import-entry', '21-import-editor', '22-import-applied',
                 '28-focus-new', '29-ev-mirrored', '31-shutter-reversed'];
  if (missing.length) report.量不到 = missing;

  return JSON.stringify(report, null, 2);
}
