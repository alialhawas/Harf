(() => {
  const root = document.querySelector('.architecture');
  const viewport = root.querySelector('.diagram-viewport');
  const picture = viewport.querySelector('img');
  const canvas = document.createElement('div');
  canvas.className = 'architecture-canvas';
  picture.before(canvas);
  canvas.append(picture);
  root.id = 'architecture-diagram';
  const ns = 'http://www.w3.org/2000/svg';
  const svg = document.createElementNS(ns, 'svg');
  svg.setAttribute('viewBox', '0 0 1000 650');
  svg.setAttribute('aria-hidden', 'true');
  svg.classList.add('architecture-flow');
  canvas.append(svg);
  const make = (tag, attributes) => {
    const node = document.createElementNS(ns, tag);
    Object.entries(attributes).forEach(([key, value]) => node.setAttribute(key, value));
    svg.append(node);
    return node;
  };
  const routes = [
    'M489 123V154H246V202', 'M338 238H401', 'M588 238H651',
    'M230 425V342H726V298', 'M455 425V365H750V300',
    'M848 268H893V463H864', 'M757 481V509', 'M855 562H941V77H610'
  ].map((d, index) => {
    const line = make('path', { d, fill: 'none', stroke: index === 3 || index === 4 ? '#c6baff' : '#b7fff0', 'stroke-width': '2.5' });
    return { line, length: line.getTotalLength() };
  });
  const nodes = [
    '437.2,7.3 619.1,112.3 562.8,144.8 380.9,39.8',
    '211.9,185 341.8,260 288.1,291 158.2,216',
    '461.9,185 591.8,260 538.1,291 408.2,216',
    '709.7,183.8 844,261.3 790.3,292.3 656,214.8',
    '198.2,402.3 335,481.3 271.8,517.8 135,438.8',
    '421.2,402.3 558,481.3 494.8,517.8 358,438.8',
    '711.7,378 858.9,463 798.3,498 651.1,413',
    '704.8,502 858.9,591 805.2,622 651.1,533'
  ].map((points, index) => make('polygon', { points, class: 'architecture-node', 'data-node': index, fill: 'transparent', stroke: '#b7fff0', 'stroke-width': '2.5' }));
  const dots = [0, 1, 2].map(() => make('circle', { r: '5', fill: '#edfffa', class: 'architecture-packet' }));
  const phases = [
    { key: 'start', duration: 1500, routes: [], from: [0], to: [0] },
    { key: 'capture', duration: 1900, routes: [0], from: [0], to: [1] },
    { key: 'buffer', duration: 1400, routes: [1], from: [1], to: [2] },
    { key: 'compare', duration: 2200, routes: [2, 3, 4], from: [2, 4, 5], to: [3] },
    { key: 'check', duration: 1800, routes: [5], from: [3], to: [6] },
    { key: 'replace', duration: 1500, routes: [6], from: [6], to: [7] },
    { key: 'return', duration: 2500, routes: [7], from: [7], to: [0] },
    { key: 'done', duration: 3000, routes: [], from: [0], to: [0] }
  ];
  const words = {
    en: {
      pause: 'Pause flow', play: 'Play flow', restart: 'Restart from the app', app: 'Text in the application',
      original: 'Original text', changed: 'Text changed · Arabic keyboard', inspect: 'Inspect the path',
      stages: ['1. Start', '2. Compare', '3. Safety', '4. Changed'],
      headings: ['Start in the application', 'Capture the keystrokes', 'Keep a short buffer', 'Compare both readings', 'Check before changing anything', 'Replace the text', 'Return to the application', 'The text has changed'],
      details: [
        'You intended Arabic, but the keyboard was in English. Follow the bright dot from the application.',
        'Harf observes the keystrokes as you type in the application and passes the captured events into its typing pipeline.',
        'The captured keys enter the buffer. A one-second pause in typing triggers the comparison.',
        'Harf renders the buffered keys in both layouts and compares the readings. Arabic has the stronger score in this example.',
        'The proposed edit moves to the safety check. The application text is still unchanged.',
        'The checks pass in this example. At the end of this step, Harf replaces the wrong-layout text.',
        'The replacement has happened. The path returns to the original app with the keyboard switched to Arabic.',
        'السلام عليكم is now in the original application. The illustration holds here, then starts a new cycle.'
      ]
    },
    ar: {
      pause: 'إيقاف المسار مؤقتًا', play: 'تشغيل المسار', restart: 'ابدأ مجددًا من التطبيق', app: 'النص داخل التطبيق',
      original: 'النص الأصلي', changed: 'تغيّر النص · اللوحة بالعربية', inspect: 'استعرض المسار',
      stages: ['١. البداية', '٢. المقارنة', '٣. الأمان', '٤. تغيّر النص'],
      headings: ['البداية داخل التطبيق', 'التقاط ضغطات المفاتيح', 'حفظ المفاتيح مؤقتًا', 'مقارنة القراءتين', 'الفحص قبل أي تغيير', 'استبدال النص', 'العودة إلى التطبيق', 'تغيّر النص الآن'],
      details: [
        'كنت تقصد العربية، لكن اللوحة كانت بالإنجليزية. تتبّع النقطة المضيئة بدءًا من التطبيق.',
        'يرصد حرف ضغطات المفاتيح أثناء الكتابة داخل التطبيق، ويمرّر الأحداث الملتقطة إلى مسار معالجة الكتابة.',
        'تدخل المفاتيح الملتقطة الذاكرة المؤقتة. يبدأ التقييم بعد توقّف الكتابة لثانية.',
        'يحوّل حرف المفاتيح المحفوظة إلى نص بالتخطيطين، ثم يقارن القراءتين. تحصل العربية على الدرجة الأعلى في هذا المثال.',
        'ينتقل التعديل المقترح إلى فحص الأمان. لم يتغيّر النص داخل التطبيق بعد.',
        'تنجح الفحوص في هذا المثال. في نهاية هذه الخطوة، يستبدل حرف النص المكتوب بالتخطيط الخطأ.',
        'تمّ الاستبدال. يعود المسار إلى التطبيق الأصلي بعد تحويل لوحة المفاتيح إلى العربية.',
        'أصبحت «السلام عليكم» داخل التطبيق الأصلي. يتوقّف الرسم قليلًا عند النتيجة، ثم يبدأ دورة جديدة.'
      ]
    }
  };
  const controls = document.createElement('div');
  controls.className = 'architecture-playback';
  const toggle = document.createElement('button');
  const restart = document.createElement('button');
  [toggle, restart].forEach(button => { button.type = 'button'; controls.append(button); });
  toggle.id = 'architecture-toggle';
  restart.id = 'architecture-restart';
  root.prepend(controls);
  const readout = document.createElement('div');
  readout.className = 'architecture-readout';
  readout.innerHTML = '<span id="architecture-app-label"></span><bdi id="architecture-text" dir="ltr">hgsghl ugd;l</bdi><span id="architecture-text-state"></span>';
  controls.after(readout);
  const explanation = document.createElement('div');
  explanation.className = 'architecture-explanation';
  explanation.setAttribute('role', 'status');
  explanation.innerHTML = '<strong id="architecture-step"></strong><p id="architecture-detail"></p>';
  viewport.after(explanation);
  const steps = document.createElement('div');
  steps.className = 'architecture-steps';
  steps.setAttribute('role', 'group');
  const stops = [0, 3, 4, 7];
  stops.forEach((value, index) => {
    const button = document.createElement('button');
    button.type = 'button';
    button.dataset.architectureStage = String(value);
    button.addEventListener('click', () => {
      enabled = false;
      phase = value;
      elapsed = value === 0 || value === 7 ? 0 : phases[value].duration;
      refresh();
    });
    steps.append(button);
  });
  explanation.after(steps);
  const motion = matchMedia('(prefers-reduced-motion: reduce)');
  let enabled = !motion.matches;
  let visible = false;
  let phase = 0;
  let elapsed = 0;
  let lastTime = null;
  let frame = null;
  let changedState = null;
  const active = () => enabled && visible && !document.hidden;

  function updateText(force = false) {
    const changed = phase > 5 || (phase === 5 && elapsed >= phases[5].duration * 0.85);
    if (!force && changed === changedState) return;
    changedState = changed;
    const text = root.querySelector('#architecture-text');
    text.textContent = changed ? 'السلام عليكم' : 'hgsghl ugd;l';
    text.dir = changed ? 'rtl' : 'ltr';
    text.lang = changed ? 'ar' : 'en';
    readout.classList.toggle('changed', changed);
    root.dataset.textChanged = String(changed);
    root.querySelector('#architecture-text-state').textContent = words[articleLocale][changed ? 'changed' : 'original'];
  }

  function draw() {
    const current = phases[phase];
    const progress = Math.min(1, elapsed / (current.duration * 0.85));
    const completed = new Set(phases.slice(0, phase).flatMap(item => item.routes));
    routes.forEach(({ line, length }, index) => {
      const moving = current.routes.includes(index);
      line.style.opacity = moving ? '1' : completed.has(index) ? '.3' : '0';
      line.setAttribute('stroke-dasharray', `${length} ${length}`);
      line.setAttribute('stroke-dashoffset', moving ? String(length * (1 - progress)) : '0');
    });
    dots.forEach((dot, index) => {
      const route = routes[current.routes[index]];
      dot.style.opacity = route ? '1' : '0';
      if (!route) return;
      const point = route.line.getPointAtLength(route.length * progress);
      dot.setAttribute('cx', point.x);
      dot.setAttribute('cy', point.y);
    });
    const lit = progress >= 1 ? current.to : current.from;
    nodes.forEach((node, index) => node.classList.toggle('active', lit.includes(index)));
    updateText();
  }

  function renderLabels() {
    const strings = words[articleLocale];
    toggle.textContent = strings[enabled ? 'pause' : 'play'];
    restart.textContent = strings.restart;
    root.querySelector('#architecture-app-label').textContent = strings.app;
    const step = articleLocale === 'ar' ? `${phase + 1} من ${phases.length}` : `${phase + 1} / ${phases.length}`;
    root.querySelector('#architecture-step').textContent = `${step} · ${strings.headings[phase]}`;
    root.querySelector('#architecture-detail').textContent = strings.details[phase];
    steps.setAttribute('aria-label', strings.inspect);
    [...steps.children].forEach((button, index) => {
      button.textContent = strings.stages[index];
      button.setAttribute('aria-pressed', String(stops[index] === phase));
    });
    root.dataset.flowStage = phases[phase].key;
    root.dataset.flowPlaying = String(enabled);
    explanation.setAttribute('aria-live', active() ? 'off' : 'polite');
    updateText(true);
  }

  function tick(now) {
    frame = null;
    if (!active()) { lastTime = null; return; }
    if (lastTime !== null) elapsed += now - lastTime;
    lastTime = now;
    if (elapsed >= phases[phase].duration) {
      phase = (phase + 1) % phases.length;
      elapsed = 0;
      renderLabels();
    }
    draw();
    frame = requestAnimationFrame(tick);
  }

  function refresh() {
    cancelAnimationFrame(frame);
    frame = null;
    lastTime = null;
    renderLabels();
    draw();
    if (active()) frame = requestAnimationFrame(tick);
  }
  toggle.addEventListener('click', () => { enabled = !enabled; refresh(); });
  restart.addEventListener('click', () => { phase = 0; elapsed = 0; refresh(); });
  new IntersectionObserver(entries => {
    visible = entries[0].isIntersecting;
    refresh();
  }, { threshold: 0.1 }).observe(root);
  document.addEventListener('visibilitychange', refresh);
  motion.addEventListener('change', () => { if (motion.matches) enabled = false; refresh(); });
  window.harfArchitecture = { refresh };
  refresh();
})();
