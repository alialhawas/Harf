const dictionaryMessages = {
  en: {
    pending: 'Learning', known: 'Known word',
    waiting: 'No dictionary credit yet', credited: 'Counts toward English dictionary coverage',
    progress: '{count} of 10 qualifying observations',
    before: 'Harf has recorded {count} of 10 qualifying observations of “webhook”. At 10, the word will contribute to English dictionary coverage.',
    after: '“webhook” has reached 10 qualifying observations and joined the English dictionary. It now contributes to language scoring; the other correction checks still apply.'
  },
  ar: {
    pending: 'قيد التعلّم', known: 'كلمة معروفة',
    waiting: 'لا تُحتسب في تغطية القاموس بعد', credited: 'تُحتسب ضمن تغطية القاموس الإنجليزي',
    progress: '{count} من ١٠ ملاحظات مستوفية للشروط',
    before: 'سجّل حرف ظهور كلمة «webhook» {count} من أصل ١٠ مرات تستوفي شروط التعلّم. عند المرة العاشرة، يبدأ احتسابها في تغطية القاموس الإنجليزي.',
    after: 'بلغت «webhook» عشر ملاحظات تستوفي الشروط، وأصبحت ضمن القاموس الإنجليزي. تُحتسب الآن في تقييم اللغة، مع استمرار بقية فحوص التصحيح.'
  }
};
let dictionarySightings = 1;
let dictionaryLocale = 'en';

function renderDictionaryDemo(locale = dictionaryLocale) {
  dictionaryLocale = locale;
  const root = document.querySelector('#dictionary-demo');
  const learned = dictionarySightings >= 10;
  const strings = dictionaryMessages[locale];
  const count = new Intl.NumberFormat(locale).format(dictionarySightings);
  const format = value => value.replace('{count}', count);
  root.dataset.learned = String(learned);
  document.querySelector('#dictionary-count').textContent = `${count} / ${new Intl.NumberFormat(locale).format(10)}`;
  document.querySelector('#dictionary-state').textContent = strings[learned ? 'known' : 'pending'];
  document.querySelector('#dictionary-credit').textContent = strings[learned ? 'credited' : 'waiting'];
  document.querySelector('#dictionary-result').textContent = format(strings[learned ? 'after' : 'before']);
  const progress = document.querySelector('#dictionary-progress');
  progress.setAttribute('aria-valuenow', String(dictionarySightings));
  progress.setAttribute('aria-valuetext', format(strings.progress));
  progress.querySelectorAll('span').forEach((cell, index) => cell.classList.toggle('filled', index < dictionarySightings));
  document.querySelectorAll('[data-dictionary-count]').forEach(button => {
    button.setAttribute('aria-pressed', String(Number(button.dataset.dictionaryCount) === dictionarySightings));
  });
  document.querySelector('#dictionary-observe').disabled = learned;
}

document.querySelectorAll('[data-dictionary-count]').forEach(button => {
  button.addEventListener('click', () => {
    dictionarySightings = Number(button.dataset.dictionaryCount);
    renderDictionaryDemo();
  });
});
document.querySelector('#dictionary-observe').addEventListener('click', () => {
  dictionarySightings = Math.min(10, dictionarySightings + 1);
  renderDictionaryDemo();
});
