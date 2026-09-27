(() => {
  const labels = {
    en: {
      pause: 'Pause animation', play: 'Play on repeat',
      bigram: '1. Letter patterns', dictionary: '2. Dictionary', combined: '3. Combined score',
      scores: [
        'Letter patterns: Arabic scores 0.823 and English 0.244. Harf multiplies this signal by 0.55 when calculating the combined score.',
        'Dictionary coverage: Arabic scores 1.000 and English 0.000. Harf multiplies this signal by 0.45, then adds it to the letter-pattern contribution.',
        'Combine the two signals: Arabic scores 0.903; English scores 0.134. The reported gap is 0.768 before rounding. The proposed correction still needs the safety checks.'
      ],
      scoreControls: 'Inspect scoring stages'
    },
    ar: {
      pause: 'إيقاف الحركة مؤقتًا', play: 'تشغيل متكرّر',
      bigram: '١. أنماط الحروف', dictionary: '٢. القاموس', combined: '٣. الدرجة النهائية',
      scores: [
        'أنماط الحروف: درجة العربية 0.823 والإنجليزية 0.244. يضرب حرف هذه الإشارة في 0.55 عند حساب الدرجة النهائية.',
        'تغطية القاموس: درجة العربية 1.000 والإنجليزية 0.000. يضرب حرف هذه الإشارة في 0.45، ثم يضيفها إلى مساهمة أنماط الحروف.',
        'نجمع الإشارتين: درجة العربية 0.903 ودرجة الإنجليزية 0.134. الفارق الذي تعرضه الأداة هو 0.768، محسوبًا قبل تقريب الدرجات. ولا يزال التصحيح المقترح يحتاج إلى فحوص الأمان.'
      ],
      scoreControls: 'استعرض مراحل حساب الدرجة'
    }
  };
  const motion = window.matchMedia('(prefers-reduced-motion: reduce)');
  const controllers = [];
  let scoreStage = 0;
  const scoreRoot = document.querySelector('.score-figure');
  const scoreControls = document.createElement('div');
  scoreControls.className = 'score-controls';
  scoreControls.setAttribute('role', 'group');
  ['bigram', 'dictionary', 'combined'].forEach((key, index) => {
    const button = document.createElement('button');
    button.type = 'button';
    button.dataset.scoreStage = String(index);
    button.dataset.label = key;
    button.addEventListener('click', () => { scoreStage = index; renderScores(); });
    scoreControls.append(button);
  });
  const scoreExplanation = document.createElement('p');
  scoreExplanation.id = 'score-explanation';
  scoreExplanation.setAttribute('role', 'status');
  scoreRoot.insertBefore(scoreControls, scoreRoot.querySelector('figcaption'));
  scoreRoot.insertBefore(scoreExplanation, scoreRoot.querySelector('figcaption'));

  function renderScores() {
    const strings = labels[articleLocale];
    scoreRoot.dataset.scoreStage = String(scoreStage);
    scoreRoot.querySelectorAll('tr').forEach(row => {
      [...row.children].forEach((cell, index) => cell.classList.toggle('score-active', index === scoreStage + 1));
    });
    scoreControls.setAttribute('aria-label', strings.scoreControls);
    scoreControls.querySelectorAll('button').forEach(button => {
      button.textContent = strings[button.dataset.label];
      button.setAttribute('aria-pressed', String(Number(button.dataset.scoreStage) === scoreStage));
    });
    scoreExplanation.textContent = strings.scores[scoreStage];
  }

  function addLoop(root, advance, duration, cancel = () => {}) {
    const toggle = document.createElement('button');
    toggle.className = 'animation-toggle';
    toggle.type = 'button';
    root.prepend(toggle);
    const controller = { root, enabled: !motion.matches, visible: false, timer: null, toggle };
    const canRun = () => controller.enabled && controller.visible && !document.hidden;
    function paint() {
      toggle.textContent = labels[articleLocale][controller.enabled ? 'pause' : 'play'];
      toggle.setAttribute('aria-label', toggle.textContent);
      root.classList.toggle('is-running', canRun());
      root.dataset.autoplay = String(controller.enabled);
      root.querySelectorAll('[role="status"]').forEach(status => status.setAttribute('aria-live', canRun() ? 'off' : 'polite'));
    }
    function sync() {
      clearTimeout(controller.timer);
      controller.timer = null;
      paint();
      if (canRun()) {
        controller.timer = setTimeout(() => {
          advance();
          sync();
        }, duration());
      }
    }
    function pause() {
      controller.enabled = false;
      cancel();
      sync();
    }
    controller.sync = sync;
    controller.pause = pause;
    toggle.addEventListener('click', () => {
      cancel();
      controller.enabled = !controller.enabled;
      sync();
    });
    root.addEventListener('click', event => {
      const button = event.target.closest('button');
      if (button && button !== toggle) pause();
    }, true);
    const observer = new IntersectionObserver(entries => {
      controller.visible = entries[0].isIntersecting;
      if (!controller.visible) cancel();
      sync();
    }, { threshold: 0.12 });
    observer.observe(root);
    controllers.push(controller);
    sync();
  }

  addLoop(document.querySelector('#dictionary-demo'), () => {
    dictionarySightings = dictionarySightings >= 10 ? 1 : dictionarySightings + 1;
    renderDictionaryDemo();
  }, () => dictionarySightings >= 10 ? 3000 : 850);

  const correctionStages = ['ready', 'type', 'compare', 'check', 'fix'];
  addLoop(document.querySelector('#correction-demo'), () => {
    if (demo.dataset.step === 'type' && capturedKeyCount < examples[language].keys.length) {
      renderCapturedKeys(capturedKeyCount + 1);
      return;
    }
    const next = correctionStages[(correctionStages.indexOf(demo.dataset.step) + 1) % correctionStages.length];
    setStage(next);
  }, () => {
    if (demo.dataset.step === 'type') {
      return capturedKeyCount < examples[language].keys.length ? captureKeyDelay(capturedKeyCount) : 900;
    }
    return demo.dataset.step === 'fix' ? 2800 : 1100;
  }, () => {
    run++;
    replay.disabled = false;
    replay.textContent = message('replay');
  });

  addLoop(scoreRoot, () => {
    scoreStage = (scoreStage + 1) % 3;
    renderScores();
  }, () => 2600);

  function refresh() {
    renderScores();
    controllers.forEach(controller => controller.sync());
  }
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) { run++; replay.disabled = false; }
    controllers.forEach(controller => controller.sync());
  });
  motion.addEventListener('change', () => {
    if (motion.matches) controllers.forEach(controller => controller.pause());
  });
  window.harfAnimations = { refresh };
  refresh();
})();
