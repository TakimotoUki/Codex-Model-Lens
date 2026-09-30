'use strict';
const preview = document.getElementById('product-screen');
for (const button of document.querySelectorAll('[data-preview]')) {
  button.addEventListener('click', () => {
    const timer = button.dataset.preview === 'timer';
    preview.src = timer ? 'assets/menu-timer.png' : 'assets/menu-usage.png';
    preview.alt = timer ? '独立的紧凑番茄钟菜单，演示画面' : '用量与任务模型菜单，明确标注为演示数据';
    for (const item of document.querySelectorAll('[data-preview]')) {
      const selected = item === button;
      item.classList.toggle('selected', selected);
      item.setAttribute('aria-pressed', String(selected));
    }
  });
}
