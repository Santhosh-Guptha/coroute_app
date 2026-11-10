/* CoRoute web admin: Engagement (3.55 ratings & reviews, docs/features_355/ratings_reviews.md).
   Templates (prompt texts in en / hi / te, quick chips per review type and place category), the
   "Rate CoRoute" timing rules, the in-app feedback inbox and review statistics. Uses the shell in
   admin.js (window.CR). Every text is set as text, never as HTML. The server refuses prices, coupons,
   rewards, incentives to rate and gating wording ("Enjoying it? Rate us") in any template. */
(function () {
  'use strict';
  var CR = window.CR;
  if (!CR) return;
  var h = CR.util.h, clear = CR.util.clear, append = CR.util.append, date = CR.util.date;
  var api = CR.api, ui = CR.ui;

  var LANG_NAMES = { en: 'English', hi: 'हिन्दी (Hindi)', te: 'తెలుగు (Telugu)' };
  var TEXT_LABELS = {
    tripTitle: ['Trip review title', 'After the ride, above the stars'],
    tripSubtitle: ['Trip review subtitle', 'Privacy line under the title'],
    noteHint: ['Note hint', 'Placeholder of the optional note (280 characters)'],
    placesTitle: ['Places title', 'Above the places the rider stopped at'],
    placesSubtitle: ['Places subtitle', ''],
    rateTitle: ['"Rate CoRoute" row', 'Settings and Profile row'],
    rateSubtitle: ['"Rate CoRoute" row subtitle', ''],
    feedbackTitle: ['"Send feedback" row', ''],
    feedbackSubtitle: ['"Send feedback" subtitle', ''],
    thanks: ['Thanks line', 'Shown after a review is saved'],
  };
  var GROUP_LABELS = { stay: 'Stay (hotels, lodges)', food: 'Food (dhabas, restaurants)', fuel: 'Fuel and EV charging', viewpoint: 'Viewpoints and heritage', other: 'Every other place' };
  var TOPIC_LABELS = { general: 'General', bug: 'Problem', idea: 'Idea', ride: 'Ride', places: 'Places', other: 'Other' };

  function clone(v) { return JSON.parse(JSON.stringify(v)); }
  function card(title, sub) {
    var c = h('div.card');
    c.appendChild(h('div.card__head', h('h3', { text: title }), sub ? h('p', { text: sub }) : null));
    return c;
  }
  function errorList(fields) {
    var keys = Object.keys(fields || {});
    if (!keys.length) return null;
    return h('div.banner.banner--bad', h('div', { text: 'Not saved. Please fix:' }),
      h('ul', keys.map(function (k) { return h('li', h('span.mono', { text: k }), ' : ', fields[k]); })));
  }

  // ==================================================================== state
  var S = null; // { version, config, defaults, history, ranges, draft, dirty, lang, tab }

  function load(view) {
    clear(view).appendChild(ui.loading());
    return api('GET', '/admin/engagement/config').then(function (r) {
      S = { version: r.version, config: r.config, defaults: r.defaults, history: r.history || [], ranges: r.ranges || {},
        textKeys: r.textKeys || {}, groups: r.chipGroups || Object.keys(GROUP_LABELS), languages: r.languages || ['en', 'hi', 'te'],
        draft: clone(r.config), dirty: false, lang: (S && S.lang) || 'en', tab: (S && S.tab) || 'templates', errors: null,
        updatedAt: r.updatedAt, updatedBy: r.updatedBy };
      render(view);
    }).catch(function (e) { clear(view).appendChild(ui.error(e)); });
  }

  function markDirty(bar) { S.dirty = true; if (bar) bar.update(); }

  function save(view) {
    return api('PUT', '/admin/engagement/config', { config: S.draft, baseVersion: S.version }).then(function (r) {
      ui.toast('Saved as version ' + r.version + '. Apps pick it up within a few minutes.');
      S.errors = null;
      return load(view);
    }).catch(function (e) {
      if (e.status === 422) { S.errors = e.body.fields || {}; render(view); ui.toast('Not saved: see the highlighted problems.', true); return; }
      if (e.status === 409) { ui.toast(e.message, true); return; }
      ui.toast(e.message, true);
    });
  }

  // ==================================================================== render
  function render(view) {
    clear(view);
    var tabs = [['templates', 'Templates'], ['rules', 'Rating prompt'], ['feedback', 'Feedback inbox'], ['stats', 'Review stats']];
    var nav = h('div.row.eng-tabs', { role: 'tablist', 'aria-label': 'Engagement' });
    tabs.forEach(function (t) {
      nav.appendChild(h('button.btn.btn--sm', { type: 'button', role: 'tab', 'aria-selected': String(S.tab === t[0]), 'aria-pressed': String(S.tab === t[0]),
        text: t[1], onclick: function () { if (S.tab !== t[0]) { S.tab = t[0]; render(view); } } }));
    });
    view.appendChild(ui.pageHead('Engagement', 'After-ride review prompts, "Rate CoRoute" timing, rider feedback and review numbers. No prices, offers or rewards: Google Play policy.', nav));
    var body = h('div');
    view.appendChild(body);
    if (S.tab === 'templates' || S.tab === 'rules') {
      var bar = saveBar(view);
      if (S.errors) body.appendChild(errorList(S.errors));
      body.appendChild(S.tab === 'templates' ? templatesTab(bar) : rulesTab(bar));
      body.appendChild(historyCard(view));
      view.appendChild(bar.el);
    } else if (S.tab === 'feedback') feedbackTab(body);
    else statsTab(body);
  }

  function saveBar(view) {
    var status = h('span.muted.small');
    var btn = h('button.btn.btn--primary', { type: 'button', text: 'Save changes' });
    var reset = h('button.btn.btn--ghost', { type: 'button', text: 'Discard' });
    var el = h('div.card.section-gap.eng-savebar', h('div.row', status, h('span.spacer'), reset, btn));
    function update() {
      status.textContent = (S.dirty ? 'Unsaved changes. ' : '') + 'Live: version ' + S.version + (S.updatedAt ? ', saved ' + date(S.updatedAt, true) + (S.updatedBy ? ' by ' + S.updatedBy : '') : ' (built-in defaults)');
      btn.disabled = !S.dirty; reset.disabled = !S.dirty;
    }
    btn.addEventListener('click', function () { btn.disabled = true; save(view).then(update); });
    reset.addEventListener('click', function () { S.draft = clone(S.config); S.dirty = false; S.errors = null; render(view); });
    update();
    return { el: el, update: update };
  }

  // ---------------------------------------------------------------- templates
  function langPicker(onChange) {
    var sel = ui.select(S.languages.map(function (l) { return [l, LANG_NAMES[l] || l]; }), S.lang, { 'aria-label': 'Language', class: 'select--sm' });
    sel.addEventListener('change', function () { S.lang = sel.value; onChange(); });
    return sel;
  }

  function templatesTab(bar) {
    var wrap = h('div');
    function draw() {
      clear(wrap);
      var lang = S.lang;
      var hint = lang === 'en' ? 'English is required. Hindi and Telugu fall back to English when empty.' : 'Leave empty to show the English text.';
      var texts = card('Prompt texts', hint);
      texts.querySelector('.card__head').appendChild(langPicker(draw));
      var grid = h('div.grid2');
      Object.keys(TEXT_LABELS).forEach(function (k) {
        var max = S.textKeys[k] || 160;
        var cur = (S.draft.texts[k] || {})[lang] || '';
        var input = h(max > 80 ? 'textarea' : 'input', { maxlength: String(max), value: cur, rows: max > 80 ? '2' : null, placeholder: lang === 'en' ? '' : ((S.draft.texts[k] || {}).en || '') });
        if (max > 80) input.value = cur;
        input.addEventListener('input', function () {
          S.draft.texts[k] = S.draft.texts[k] || {};
          var v = input.value.trim();
          if (v) S.draft.texts[k][lang] = v; else delete S.draft.texts[k][lang];
          markDirty(bar);
        });
        var errKey = 'texts.' + k + '.' + lang;
        grid.appendChild(h('div', ui.field(TEXT_LABELS[k][0], input, TEXT_LABELS[k][1] || ('up to ' + max)),
          S.errors && S.errors[errKey] ? h('p.form-error', { text: S.errors[errKey] }) : null));
      });
      texts.appendChild(grid);
      wrap.appendChild(texts);

      var trip = card('Trip review chips', 'Quick chips under "How was the ride?". Riders may pick several. Up to 10.');
      trip.appendChild(chipEditor(S.draft.tripChips, 'tripChips', bar, draw));
      wrap.appendChild(trip);

      var places = card('Place review chips', 'Per place category. Fuel includes EV charging, Viewpoints include heritage sites.');
      var pg = h('div.cards');
      S.groups.forEach(function (g) {
        S.draft.placeChips[g] = S.draft.placeChips[g] || [];
        pg.appendChild(h('div.card', h('div.card__head', h('h3', { text: GROUP_LABELS[g] || g })), chipEditor(S.draft.placeChips[g], 'placeChips.' + g, bar, draw)));
      });
      places.appendChild(pg);
      wrap.appendChild(places);
      wrap.appendChild(previewCard());
    }
    draw();
    return wrap;
  }

  /** Rows of id + label (in the language picked) with up / down / remove, and "Add chip". */
  function chipEditor(list, path, bar, redraw) {
    var box = h('div.stack');
    var lang = S.lang;
    list.forEach(function (c, i) {
      var id = h('input.mono', { value: c.id, maxlength: '32', 'aria-label': 'Chip id', spellcheck: 'false', disabled: lang !== 'en' });
      var label = h('input', { value: (c.label || {})[lang] || '', maxlength: '28', 'aria-label': 'Label', placeholder: lang === 'en' ? 'Label' : ((c.label || {}).en || '') });
      id.addEventListener('input', function () { c.id = id.value.trim().toLowerCase(); markDirty(bar); });
      label.addEventListener('input', function () { c.label = c.label || {}; var v = label.value.trim(); if (v) c.label[lang] = v; else delete c.label[lang]; markDirty(bar); });
      var up = h('button.btn.btn--ghost.btn--icon', { type: 'button', 'aria-label': 'Move up', text: '↑', disabled: i === 0, onclick: function () { list.splice(i - 1, 0, list.splice(i, 1)[0]); markDirty(bar); redraw(); } });
      var rm = h('button.btn.btn--ghost.btn--icon', { type: 'button', 'aria-label': 'Remove chip', text: '×', onclick: function () { list.splice(i, 1); markDirty(bar); redraw(); } });
      var errs = S.errors ? Object.keys(S.errors).filter(function (k) { return k.indexOf(path + '[' + i + ']') === 0; }) : [];
      box.appendChild(h('div', h('div.row', h('div', { style: null }, id), label, up, rm),
        errs.length ? h('p.form-error', { text: errs.map(function (k) { return S.errors[k]; }).join(' ') }) : null));
    });
    if (S.errors && S.errors[path]) box.appendChild(h('p.form-error', { text: S.errors[path] }));
    var add = h('button.btn.btn--sm', { type: 'button', text: '+ Add chip', disabled: list.length >= 10 || lang !== 'en',
      onclick: function () { list.push({ id: 'chip_' + (list.length + 1), label: { en: 'New chip' } }); markDirty(bar); redraw(); } });
    box.appendChild(h('div.row', add, lang !== 'en' ? h('span.muted.small', { text: 'Switch to English to add chips or change ids.' }) : null));
    return box;
  }

  function pick(t) { return (t && (t[S.lang] || t.en)) || ''; }
  function previewCard() {
    var d = S.draft;
    var c = card('Preview', 'Roughly how the after-ride card reads in the app (' + (LANG_NAMES[S.lang] || S.lang) + ').');
    c.appendChild(h('div.eng-preview',
      h('b', { text: pick(d.texts.tripTitle) }),
      h('div.muted.small', { text: pick(d.texts.tripSubtitle) }),
      h('div.eng-stars', { 'aria-hidden': 'true', text: '\u2605 \u2605 \u2605 \u2605 \u2606' }),
      h('div.ph-chips', d.tripChips.map(function (x) { return h('span.chip', { text: pick(x.label) }); })),
      h('div.muted.small', { text: pick(d.texts.noteHint) }),
      h('hr'),
      h('b', { text: pick(d.texts.placesTitle) }),
      h('div.muted.small', { text: pick(d.texts.placesSubtitle) }),
      h('div.ph-chips', (d.placeChips.stay || []).map(function (x) { return h('span.chip', { text: pick(x.label) }); }))));
    return c;
  }

  // ---------------------------------------------------------------- rules
  function numberField(obj, key, rangeKey, label, hint, bar) {
    var r = S.ranges[rangeKey] || [0, 999];
    var input = h('input', { type: 'number', min: String(r[0]), max: String(r[1]), step: '1', value: String(obj[key]) });
    input.addEventListener('input', function () { obj[key] = input.value === '' ? '' : Number(input.value); markDirty(bar); });
    return h('div', ui.field(label, input, hint + ' (' + r[0] + ' to ' + r[1] + ')'), S.errors && S.errors[rangeKey] ? h('p.form-error', { text: S.errors[rangeKey] }) : null);
  }
  function toggle(obj, key, label, bar) {
    var cb = h('input', { type: 'checkbox', checked: obj[key] === true });
    cb.addEventListener('change', function () { obj[key] = cb.checked; markDirty(bar); });
    return h('label.check', cb, label);
  }

  function rulesTab(bar) {
    var d = S.draft;
    var wrap = h('div');
    var rp = card('"Rate CoRoute" prompt (Google Play in-app review)',
      'The app opens Google\'s own review card. It never asks first whether the rider is happy, and every rider gets the same card. Google may still decide not to show it.');
    rp.appendChild(h('div.stack',
      toggle(d.ratingPrompt, 'enabled', 'Ask riders to rate CoRoute after rides', bar),
      h('div.grid3',
        numberField(d.ratingPrompt, 'afterRides', 'ratingPrompt.afterRides', 'After completed ride number', 'Rides without SOS or crash alarm', bar),
        numberField(d.ratingPrompt, 'cooldownDays', 'ratingPrompt.cooldownDays', 'Days between asks', 'Minimum gap', bar),
        numberField(d.ratingPrompt, 'maxPerYear', 'ratingPrompt.maxPerYear', 'Asks per year', 'At most', bar)),
      h('ul.muted.small',
        h('li', { text: 'Never during a ride: on the ride summary after it closes, or at the next app open.' }),
        h('li', { text: 'Never after a problem: SOS, crash alarm, failed SOS, or a session with many errors.' }),
        h('li', { text: 'The "Rate CoRoute" rows in Settings and Profile always work and do not count as asks.' }))));
    wrap.appendChild(rp);
    var rv = card('After-ride reviews', 'One calm screen after the ride: the trip first, then up to 2 places the rider stopped at. Always skippable.');
    rv.appendChild(h('div.stack',
      h('div.row', toggle(d.reviews, 'tripEnabled', 'Ask "How was the ride?"', bar), toggle(d.reviews, 'placesEnabled', 'Ask about places the rider stopped at', bar)),
      h('div.grid2',
        numberField(d.reviews, 'maxPlaces', 'reviews.maxPlaces', 'Places per ride', 'Longest stays first', bar),
        numberField(d.reviews, 'reportDays', 'reviews.reportDays', 'Trip report asks for', 'Days after a skipped ride', bar))));
    wrap.appendChild(rv);
    return wrap;
  }

  function historyCard(view) {
    var c = card('Versions', 'The last 10 saved versions. Restoring saves it again as a new version.');
    var tb = h('tbody');
    if (!S.history.length) tb.appendChild(h('tr', h('td', { colspan: '4', class: 'empty', text: 'Built-in defaults: nothing saved yet.' })));
    S.history.forEach(function (x) {
      var live = x.version === S.version;
      tb.appendChild(h('tr', h('td.num', { text: 'v' + x.version }), h('td.nowrap', { text: date(x.at, true) }), h('td', { text: (x.by || '') + (x.note ? ' · ' + x.note : '') }),
        h('td.num', live ? ui.chip('Live', 'ok') : h('button.btn.btn--sm', { type: 'button', text: 'Restore', onclick: function () {
          ui.confirm('Restore version ' + x.version + '?', 'Its texts, chips and rules become live again as a new version.', 'Restore').then(function (ok) {
            if (!ok) return;
            api('POST', '/admin/engagement/config/restore', { version: x.version, baseVersion: S.version }).then(function (r) { ui.toast('Restored as version ' + r.version + '.'); load(view); })
              .catch(function (e) { ui.toast(e.message, true); });
          });
        } }))));
    });
    c.appendChild(h('div.table-wrap', h('table.table', h('thead', h('tr', ['Version', 'Saved', 'By', ''].map(function (t, i) { return h('th', { class: i === 0 || i === 3 ? 'num' : '', text: t }); }))), tb)));
    c.classList.add('section-gap');
    return c;
  }

  // ---------------------------------------------------------------- feedback inbox
  function feedbackTab(body) {
    var q = h('input', { type: 'search', placeholder: 'Search text, name, version', 'aria-label': 'Search feedback' });
    var st = ui.select([['OPEN', 'Open'], ['HANDLED', 'Handled'], ['', 'All']], 'OPEN', { 'aria-label': 'Status', class: 'select--sm' });
    var counts = h('span.muted.small');
    var list = h('div');
    body.appendChild(h('div.toolbar', q, st, h('span.spacer'), counts));
    body.appendChild(list);
    var timer = null;
    q.addEventListener('input', function () { clearTimeout(timer); timer = setTimeout(run, 300); });
    st.addEventListener('change', run);
    function run() {
      clear(list).appendChild(ui.loading());
      var qs = '?limit=300' + (st.value ? '&status=' + st.value : '') + (q.value.trim() ? '&q=' + encodeURIComponent(q.value.trim()) : '');
      api('GET', '/admin/engagement/feedback' + qs).then(function (r) {
        clear(list);
        counts.textContent = r.counts.open + ' open · ' + r.counts.handled + ' handled · ' + r.counts.total + ' total';
        if (!r.items.length) { list.appendChild(h('div.card', h('div.empty', { text: 'No feedback here.' }))); return; }
        var tb = h('tbody');
        r.items.forEach(function (f) {
          var btn = h('button.btn.btn--sm', { type: 'button', text: f.status === 'HANDLED' ? 'Reopen' : 'Mark handled' });
          btn.addEventListener('click', function () {
            btn.disabled = true;
            api('PUT', '/admin/engagement/feedback/' + encodeURIComponent(f.feedbackId), { handled: f.status !== 'HANDLED' })
              .then(function () { ui.toast(f.status === 'HANDLED' ? 'Reopened.' : 'Marked handled.'); run(); })
              .catch(function (e) { btn.disabled = false; ui.toast(e.message, true); });
          });
          tb.appendChild(h('tr',
            h('td.nowrap', { text: date(f.createdAt, true) }),
            h('td', ui.chip(TOPIC_LABELS[f.topic] || f.topic, f.topic === 'bug' ? 'warn' : 'info')),
            h('td', h('div.eng-msg', { text: f.message }), f.adminNote ? h('div.muted.small', { text: 'Note: ' + f.adminNote }) : null),
            h('td', h('div', { text: f.userName || 'Rider' }), f.email ? h('div.muted.small', { text: f.email }) : h('div.muted.small', { text: 'no contact' })),
            h('td.nowrap.muted.small', { text: [f.appVersion, f.platform].filter(Boolean).join(' · ') || '-' }),
            h('td.num', f.status === 'HANDLED' ? ui.chip('Handled', 'ok') : ui.chip('Open', 'warn'), ' ', btn)));
        });
        list.appendChild(h('div.table-wrap', h('table.table', h('thead', h('tr', ['When', 'Topic', 'Message', 'From', 'App', ''].map(function (t, i) { return h('th', { class: i === 5 ? 'num' : '', text: t }); }))), tb)));
      }).catch(function (e) { clear(list).appendChild(ui.error(e)); });
    }
    run();
  }

  // ---------------------------------------------------------------- stats
  var MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  function dayLabel(ms) { var d = new Date(ms + 330 * 60000); return d.getUTCDate() + ' ' + MONTHS[d.getUTCMonth()]; }
  function fmtAvg(v) { return v === null || v === undefined ? '-' : v.toFixed(1) + ' \u2605'; }

  function statsTab(body) {
    var range = ui.select([['30', 'Last 30 days'], ['90', 'Last 90 days'], ['365', 'Last 12 months']], '90', { 'aria-label': 'Range', class: 'select--sm' });
    var out = h('div');
    body.appendChild(h('div.toolbar', range));
    body.appendChild(out);
    range.addEventListener('change', run);
    function chipChart(title, chips) {
      var top = (chips || []).slice(0, 12);
      var c = h('div.card', h('div.card__head', h('h3', { text: title })));
      if (!top.length) { c.appendChild(h('div.empty', { text: 'No chips picked yet.' })); return c; }
      c.appendChild(CR.chart({ kind: 'bar', title: title, labels: top.map(function (x) { return x.label; }), values: top.map(function (x) { return x.count; }),
        format: function (i) { return top[i].count + ' times'; }, tick: function (i) { return top.length <= 8 ? top[i].label.slice(0, 12) : ''; } }));
      return c;
    }
    function run() {
      clear(out).appendChild(ui.loading());
      api('GET', '/admin/engagement/stats?days=' + range.value).then(function (r) {
        clear(out);
        append(out, [h('div.tiles',
          ui.tile('Trip rating', fmtAvg(r.trip.avg), r.trip.count + ' reviews · ' + r.trip.withNote + ' with a note'),
          ui.tile('Place rating', fmtAvg(r.places.avg), r.places.count + ' reviews'),
          ui.tile('Open feedback', String(r.feedback.open), r.feedback.total + ' total'))]);
        var grid = h('div.chart-grid');
        var dist = r.trip.distribution || [0, 0, 0, 0, 0];
        grid.appendChild(h('div.card', h('div.card__head', h('h3', { text: 'Trip ratings' })),
          CR.chart({ kind: 'bar', title: 'Trip ratings', labels: ['1 \u2605', '2 \u2605', '3 \u2605', '4 \u2605', '5 \u2605'], values: dist, format: function (i) { return dist[i] + ' rides'; } })));
        var wk = (r.trip.weekly || []).filter(function (w, i, a) { return i >= a.length - Math.ceil(r.days / 7); });
        grid.appendChild(h('div.card', h('div.card__head', h('h3', { text: 'Reviews per week' })),
          CR.chart({ kind: 'line', title: 'Trip reviews per week', labels: wk.map(function (w) { return dayLabel(w.weekStart); }), values: wk.map(function (w) { return w.count; }),
            format: function (i) { return wk[i].count + ' reviews' + (wk[i].avg ? ' · ' + wk[i].avg.toFixed(1) + ' \u2605' : ''); } })));
        grid.appendChild(chipChart('Trip chips', r.trip.chips));
        var cats = r.places.categories || [];
        var pc = h('div.card', h('div.card__head', h('h3', { text: 'Place ratings by category' })));
        if (!cats.length) pc.appendChild(h('div.empty', { text: 'No place reviews yet.' }));
        else {
          var tb = h('tbody');
          cats.forEach(function (c) { tb.appendChild(h('tr', h('td', { text: c.category }), h('td.num', { text: String(c.count) }), h('td.num', { text: fmtAvg(c.avg) }))); });
          pc.appendChild(h('div.table-wrap', h('table.table', h('thead', h('tr', ['Category', 'Reviews', 'Average'].map(function (t, i) { return h('th', { class: i ? 'num' : '', text: t }); }))), tb)));
        }
        grid.appendChild(pc);
        Object.keys(GROUP_LABELS).forEach(function (g) {
          if ((r.places.chips[g] || []).length) grid.appendChild(chipChart('Place chips: ' + GROUP_LABELS[g], r.places.chips[g]));
        });
        out.appendChild(grid);
      }).catch(function (e) { clear(out).appendChild(ui.error(e)); });
    }
    run();
  }

  CR.sections.engagement = {
    title: 'Engagement',
    render: function (view) { load(view); },
    teardown: function () { /* nothing kept running */ },
  };
})();
