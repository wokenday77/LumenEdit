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

  // ---- 03 设置页：顶栏「更多」→ 设置 ----
  await page.click('#btnMore');
  await page.waitForTimeout(250);
  await page.click('.more-menu button[data-act="settings"]');
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

  report.截图 = ['01-normal', '02-dial', '03-settings', '04-filter(真实鼠标·现场证据)',
                 '05-filter', '06-scenestyle', '07-keep-settings', '08-switches-effect'];
  if (missing.length) report.量不到 = missing;

  return JSON.stringify(report, null, 2);
}
