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
  if (missing.length) report.量不到 = missing;

  return JSON.stringify(report, null, 2);
}
