'use strict';
const root = document.documentElement;
const toggle = document.getElementById('theme-toggle');
const symbol = document.getElementById('theme-symbol');
const media = matchMedia('(prefers-color-scheme: dark)');
let explicitTheme = false;
try { explicitTheme = ['light', 'dark'].includes(localStorage.getItem('model-lens-theme')); } catch {}
function applyTheme(theme) {
  root.dataset.theme = theme;
  const dark = theme === 'dark';
  toggle.setAttribute('aria-pressed', String(dark));
  toggle.setAttribute('aria-label', dark ? '切换为浅色外观' : '切换为深色外观');
  toggle.title = dark ? '切换为浅色外观' : '切换为深色外观';
  symbol.textContent = dark ? '☀' : '☾';
  document.querySelector('meta[name="theme-color"]').content = dark ? '#090b10' : '#fafbfe';
}
applyTheme(root.dataset.theme);
toggle.addEventListener('click', () => {
  const next = root.dataset.theme === 'dark' ? 'light' : 'dark';
  explicitTheme = true;
  applyTheme(next);
  try { localStorage.setItem('model-lens-theme', next); } catch {}
});
media.addEventListener('change', event => { if (!explicitTheme) applyTheme(event.matches ? 'dark' : 'light'); });
const preview = document.getElementById('product-screen');
const previewTitle = document.getElementById('preview-title');
const previewDescription = document.getElementById('preview-description');
for (const button of document.querySelectorAll('[data-preview]')) {
  button.addEventListener('click', () => {
    const timer = button.dataset.preview === 'timer';
    preview.src = timer ? 'assets/menu-timer.png' : 'assets/menu-usage.png';
    preview.alt = timer ? '紧凑的独立番茄钟菜单，演示数据' : 'Codex 用量与模型菜单，演示数据';
    previewTitle.replaceChildren(document.createTextNode(timer ? '把注意力，交给这一刻。' : '所有关键状态，就在菜单栏。'));
    previewDescription.textContent = timer ? '自定义专注与休息时间。开始、暂停、恢复，菜单栏显示秒级倒计时。计时与 Agent 检测保持独立，不因切换界面而停止。' : '选择需要的平台，查看正在运行的 Codex 任务、额度窗口、Token 与重置卡。品牌图标统一为单色，选中时使用系统蓝色。';
    for (const item of document.querySelectorAll('[data-preview]')) {
      const selected = item === button;
      item.classList.toggle('selected', selected);
      item.setAttribute('aria-pressed', String(selected));
    }
  });
}
