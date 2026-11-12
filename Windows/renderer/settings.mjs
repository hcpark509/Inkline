import shared from '../src/shared.cjs';
const { colors, htmlEscape } = shared;
const api = window.inkline;
let current;
function render(state) {
  current = state;
  for (const [name, value] of Object.entries(colors(state.settings.theme, state.dark)))
    document.documentElement.style.setProperty('--' + name, value);
  document.documentElement.style.colorScheme = state.dark ? 'dark' : 'light';
  for (const field of document.querySelectorAll('[data-setting]')) {
    const value = state.settings[field.dataset.setting];
    if (field.type === 'checkbox') field.checked = value;
    else if (document.activeElement !== field) field.value = value;
  }
  const families = [
    ...new Set([
      'Consolas',
      'Cascadia Code',
      'Courier New',
      'Georgia',
      'Arial',
      'Segoe UI',
      'Times New Roman',
      'Verdana',
      'Cambria',
      'Calibri',
      ...state.fonts.map((f) => f.family),
    ]),
  ].sort();
  document.querySelector('#fontFamilies').replaceChildren(
    ...families.map((f) => {
      const option = document.createElement('option');
      option.value = f;
      return option;
    }),
  );
  document.querySelector('#importedFonts').textContent = state.fonts.length
    ? [...new Set(state.fonts.map((f) => f.family))].join(' · ')
    : 'No imported fonts yet.';
  document.querySelector('#themeSamples').innerHTML = [false, true]
    .map((dark) => {
      const c = colors(state.settings.theme, dark);
      return `<div class="theme-sample" style="background:${c.source};color:${c.muted}">${dark ? 'Dark' : 'Light'}<br><span style="color:${c.purple}"># A new page</span><br><span style="color:${c.blue}">**A clear idea**</span><br><span style="color:${c.teal}">[A useful link](…)</span><br><span style="color:${c.orange}">\u0060some code\u0060</span></div>`;
    })
    .join('');
}
api.onState(render);
for (const button of document.querySelectorAll('[data-section]'))
  button.addEventListener('click', () => {
    for (const b of document.querySelectorAll('[data-section]'))
      b.classList.toggle('selected', b === button);
    for (const section of document.querySelectorAll('main>section'))
      section.hidden = section.id !== button.dataset.section;
  });
for (const field of document.querySelectorAll('[data-setting]'))
  field.addEventListener('change', async () => {
    const status = document.querySelector('#settingsStatus');
    try {
      const value =
        field.type === 'checkbox'
          ? field.checked
          : field.type === 'number'
            ? Number(field.value)
            : field.value;
      render(await api.call('settings', { [field.dataset.setting]: value }));
      status.textContent = 'Saved';
    } catch (e) {
      status.textContent = e.message;
      render(current);
    }
  });
document.querySelector('#importFonts').addEventListener('click', async () => {
  try {
    render(await api.call('import-fonts'));
    document.querySelector('#settingsStatus').textContent = 'Font library updated';
  } catch (e) {
    document.querySelector('#settingsStatus').textContent = e.message;
  }
});
render(await api.call('state'));
