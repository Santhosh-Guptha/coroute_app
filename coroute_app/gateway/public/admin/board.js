/* CoRoute web admin: Board section (3.56 marketing board on the website, src/board.js).
   Posts: updates, offers, safety tips and events, each with a title, plain text, an optional link to a page of
   the website, an optional image (JPEG / PNG / WebP up to 2 MB, EXIF removed by the gateway), an optional coupon
   (the website shows "Copy code" and "Use on plans"), a publish window in India time, pinned, and draft /
   published / archived. Website only: nothing here is ever sent to the app.
   APIs: GET/POST /api/admin/board, PATCH/DELETE /api/admin/board/:id, POST /api/admin/board/images,
   GET /api/admin/board/images/:id, GET /api/admin/board/coupons. All text is set as text, never HTML. */
(function () {
  'use strict';
  var CR = window.CR;
  if (!CR || !CR.util) return;
  var u = CR.util; var ui = CR.ui; var h = u.h; var clear = u.clear;
  var KINDS = [['update', 'Update'], ['offer', 'Offer'], ['safety_tip', 'Safety tip'], ['event', 'Event']];
  var KIND_LABEL = { update: 'Update', offer: 'Offer', safety_tip: 'Safety tip', event: 'Event' };
  var STATUS = { draft: ['Draft', ''], published: ['Published', 'ok'], archived: ['Archived', 'warn'] };
  var LINK = /^\/(?!\/)(?!api(?:\/|$))(?!admin(?:\/|$))[A-Za-z0-9\-._~/]*(?:\?[A-Za-z0-9\-._~=&%]*)?(?:#[A-Za-z0-9\-_]*)?$/;
  var PAGES = [['', 'No link'], ['/plans', 'Plans'], ['/features', 'Features'], ['/safety', 'Safety'], ['/how-it-works', 'How it works'], ['/get', 'Get the app'], ['/leaderboard', 'Leaderboards'], ['/updates', 'All updates'], ['/about', 'About']];

  var blobUrls = [];
  function imageUrl(id) {
    // Admin images need the Bearer token: fetched, then shown from a blob: URL (allowed by the admin CSP).
    return CR.api('GET', '/admin/board/images/' + encodeURIComponent(id), null, { raw: true })
      .then(function (res) { return res.blob(); })
      .then(function (b) { var url = URL.createObjectURL(b); blobUrls.push(url); return url; });
  }
  function windowText(p) {
    if (!p.startAt && !p.endAt) return 'Always';
    return (p.startAt ? u.date(p.startAt, true) : 'now') + ' → ' + (p.endAt ? u.date(p.endAt, true) : 'no end');
  }
  function statusChip(p) {
    var s = STATUS[p.status] || [p.status, ''];
    var chips = [ui.chip(s[0], s[1])];
    if (p.status === 'published') chips.push(p.visibleNow ? ui.chip('On the website', 'info') : ui.chip(p.startAt && p.startAt > Date.now() ? 'Scheduled' : 'Ended', ''));
    if (p.pinned) chips.push(ui.chip('Pinned', 'info'));
    return chips;
  }

  /** The post as the website card shows it (same structure and words as assets/board.js). */
  function previewCard(d, imgSrc) {
    var card = h('article.bd-prev', { class: 'bd-prev' + (d.pinned ? ' is-pinned' : '') });
    if (imgSrc) card.appendChild(h('div.bd-prev__media', h('img', { src: imgSrc, alt: '' })));
    var inner = h('div.bd-prev__inner');
    inner.appendChild(h('p.bd-prev__meta', ui.chip(KIND_LABEL[d.kind] || 'Update', d.kind === 'offer' ? 'warn' : d.kind === 'safety_tip' ? 'ok' : 'info'), d.pinned ? ui.chip('Pinned') : null,
      h('span', { text: u.date(d.startAt || Date.now()) })));
    inner.appendChild(h('h3', { text: d.title || 'Title' }));
    var body = h('div.bd-prev__body');
    String(d.body || 'Text of the post.').split(/\n{2,}/).forEach(function (para) {
      var pEl = h('p');
      para.split('\n').forEach(function (line, i) { if (i) pEl.appendChild(h('br')); pEl.appendChild(document.createTextNode(line)); });
      body.appendChild(pEl);
    });
    inner.appendChild(body);
    if (d.coupon) {
      inner.appendChild(h('div.bd-prev__coupon', h('div', h('small', { text: d.coupon.text || 'Code' }), h('b', { text: d.coupon.code })),
        h('div.row', h('span.btn.btn--sm', { text: 'Copy code' }), h('span.btn.btn--sm.btn--primary', { text: 'Use on plans' }))));
    }
    if (d.link) inner.appendChild(h('p.bd-prev__link', { text: (d.linkLabel || 'Read more') + ' →' }));
    if (d.endAt && d.kind !== 'safety_tip') inner.appendChild(h('p.muted.small', { text: 'Until ' + u.date(d.endAt - 1) }));
    card.appendChild(inner);
    return card;
  }

  CR.sections.board = {
    title: 'Board',
    teardown: function () { blobUrls.forEach(function (x) { URL.revokeObjectURL(x); }); blobUrls = []; },
    render: function (view) {
      var st = { posts: [], coupons: [], filter: '' };
      var tbody = h('tbody');
      var filter = ui.select([['', 'All posts'], ['published', 'Published'], ['draft', 'Drafts'], ['archived', 'Archived']], '', { 'aria-label': 'Show' });
      filter.addEventListener('change', function () { st.filter = filter.value; draw(); });
      view.appendChild(ui.pageHead('Board', '"Latest from CoRoute" on the website: the home page shows the top 3, /updates shows all. Website only, never sent to the app.',
        h('div.row',
          h('a.btn', { href: '/updates', target: '_blank', rel: 'noopener', text: 'Open /updates' }),
          h('button.btn.btn--primary', { type: 'button', text: 'New post', onclick: function () { edit(null); } }))));
      view.appendChild(h('div.toolbar', filter));
      view.appendChild(h('div.table-wrap', h('table.table', h('thead', h('tr', ['Title', 'Kind', 'Status', 'Window (India time)', 'Coupon', 'Updated'].map(function (c) { return h('th', { text: c }); }))), tbody)));

      function load() {
        clear(tbody).appendChild(h('tr', h('td', { colspan: '6', class: 'empty', text: 'Loading…' })));
        return CR.api('GET', '/admin/board').then(function (r) { st.posts = r.posts || []; draw(); })
          .catch(function (e) { clear(tbody).appendChild(h('tr', h('td', { colspan: '6' }, ui.error(e)))); });
      }
      function loadCoupons() {
        return CR.api('GET', '/admin/board/coupons').then(function (r) { st.coupons = r.coupons || []; return st.coupons; }).catch(function () { return []; });
      }
      function draw() {
        clear(tbody);
        var rows = st.posts.filter(function (p) { return !st.filter || p.status === st.filter; });
        if (!rows.length) { tbody.appendChild(h('tr', h('td', { colspan: '6', class: 'empty', text: st.posts.length ? 'No posts match.' : 'No posts yet. Write the first one with "New post".' }))); return; }
        rows.forEach(function (p) {
          tbody.appendChild(h('tr.is-link', { tabindex: '0', onclick: function () { edit(p); }, onkeydown: function (e) { if (e.key === 'Enter') edit(p); } },
            h('td', h('b', { text: p.title }), h('div.muted.small', { text: String(p.body || '').slice(0, 90) + (String(p.body || '').length > 90 ? '…' : '') })),
            h('td', { text: KIND_LABEL[p.kind] || p.kind }),
            h('td', statusChip(p)),
            h('td.small', { text: windowText(p) }),
            h('td.mono', { text: p.couponCode || '-' }),
            h('td.nowrap.small', { text: u.date(p.updatedAt, true) + (p.updatedBy ? ' · ' + p.updatedBy : '') })));
        });
      }

      function edit(p) {
        var d = p ? JSON.parse(JSON.stringify(p)) : { kind: 'update', title: '', body: '', link: null, linkLabel: null, imageId: null, couponCode: null, startAt: null, endAt: null, pinned: false, status: 'draft' };
        var imgSrc = null;
        var f = {
          kind: ui.select(KINDS, d.kind, { 'aria-label': 'Kind' }),
          title: h('input', { type: 'text', maxlength: '80', value: d.title || '', placeholder: 'e.g. Monsoon riding: five checks before you leave' }),
          body: h('textarea', { rows: '6', maxlength: '600', value: d.body || '', placeholder: 'Plain text. Line breaks are kept.' }),
          linkSel: ui.select(PAGES.concat(d.link && !PAGES.some(function (x) { return x[0] === d.link; }) ? [[d.link, d.link]] : []), d.link || '', { 'aria-label': 'Link' }),
          linkOther: h('input', { type: 'text', maxlength: '200', placeholder: 'or another page, like /safety#sos', value: '' }),
          linkLabel: h('input', { type: 'text', maxlength: '40', value: d.linkLabel || '', placeholder: 'Read more' }),
          coupon: h('select', { 'aria-label': 'Coupon' }),
          start: h('input', { type: 'datetime-local', value: d.startAt ? u.toLocalInput(d.startAt) : '' }),
          end: h('input', { type: 'datetime-local', value: d.endAt ? u.toLocalInput(d.endAt) : '' }),
          pinned: h('input', { type: 'checkbox', checked: !!d.pinned }),
          file: h('input', { type: 'file', accept: 'image/jpeg,image/png,image/webp', 'aria-label': 'Image' }),
        };
        var titleCount = h('small.muted'); var bodyCount = h('small.muted');
        var imgBox = h('div.row');
        var prevBox = h('div.bd-prev-wrap');
        var err = h('p.form-error', { role: 'alert', hidden: true });
        f.coupon.appendChild(h('option', { value: '', text: 'No coupon' }));
        if (d.couponCode) f.coupon.appendChild(h('option', { value: d.couponCode, text: d.couponCode + ' (saved)', selected: true }));
        loadCoupons().then(function (list) {
          list.forEach(function (c) {
            if (c.code === d.couponCode) return;
            f.coupon.appendChild(h('option', { value: c.code, text: c.code + ' · ' + c.text + ' · ' + (c.status === 'SCHEDULED' ? 'scheduled' : 'active') + (c.expiresAt ? ' until ' + u.date(c.expiresAt) : '') + (c.private ? ' · private (not shown)' : '') }));
          });
          refresh();
        });

        function collect() {
          var link = f.linkOther.value.trim() || f.linkSel.value || '';
          var code = f.coupon.value || '';
          var c = st.coupons.filter(function (x) { return x.code === code; })[0];
          return {
            kind: f.kind.value, title: f.title.value.trim(), body: f.body.value.replace(/\r\n?/g, '\n').trim(), link: link || null, linkLabel: f.linkLabel.value.trim() || null,
            imageId: d.imageId || null, couponCode: code || null, coupon: code ? { code: code, text: c ? c.text : '' } : null,
            startAt: f.start.value ? u.fromLocalInput(f.start.value) : null, endAt: f.end.value ? u.fromLocalInput(f.end.value) : null, pinned: f.pinned.checked,
          };
        }
        function refresh() {
          var x = collect();
          titleCount.textContent = x.title.length + ' / 80';
          bodyCount.textContent = x.body.length + ' / 600';
          clear(prevBox).appendChild(previewCard(x, imgSrc));
        }
        function drawImage() {
          clear(imgBox);
          if (d.imageId) {
            imgBox.appendChild(h('span.chip.chip--ok', { text: 'Image added' }));
            imgBox.appendChild(h('button.btn.btn--sm', { type: 'button', text: 'Remove image', onclick: function () { d.imageId = null; imgSrc = null; drawImage(); refresh(); } }));
          } else imgBox.appendChild(f.file);
        }
        f.file.addEventListener('change', function () {
          var file = f.file.files && f.file.files[0];
          if (!file) return;
          if (!/^image\/(jpeg|png|webp)$/.test(file.type)) { ui.toast('Choose a JPEG, PNG or WebP image.', true); f.file.value = ''; return; }
          if (file.size > 2 * 1024 * 1024) { ui.toast('This image is larger than 2 MB.', true); f.file.value = ''; return; }
          CR.api('POST', '/admin/board/images', file, { type: file.type }).then(function (r) {
            d.imageId = r.image.id;
            return imageUrl(r.image.id).then(function (url) { imgSrc = url; drawImage(); refresh(); ui.toast('Image uploaded (location data removed).'); });
          }).catch(function (e) { ui.toast(e.message, true); f.file.value = ''; });
        });
        [f.kind, f.title, f.body, f.linkSel, f.linkOther, f.linkLabel, f.coupon, f.start, f.end, f.pinned].forEach(function (x) { x.addEventListener('input', refresh); x.addEventListener('change', refresh); });
        if (d.imageId) imageUrl(d.imageId).then(function (url) { imgSrc = url; refresh(); }).catch(function () { /* missing image */ });
        drawImage();

        function check(x) {
          if (!x.title) return 'Write a title.';
          if (x.title.length > 80) return 'The title can be at most 80 characters.';
          if (!x.body) return 'Write the text of the post.';
          if (x.body.length > 600) return 'The text can be at most 600 characters.';
          if (x.link && (!LINK.test(x.link) || x.link.indexOf('..') >= 0)) return 'The link must be a page of this website, like /plans or /safety.';
          if (x.startAt && x.endAt && x.endAt <= x.startAt) return 'The post must end after it starts.';
          return '';
        }
        function save(status) {
          var x = collect();
          var problem = check(x);
          if (problem) { err.hidden = false; err.textContent = problem; return Promise.resolve(false); }
          err.hidden = true;
          var body = { kind: x.kind, title: x.title, body: x.body, link: x.link, linkLabel: x.linkLabel, imageId: x.imageId, couponCode: x.couponCode, startAt: x.startAt, endAt: x.endAt, pinned: x.pinned, status: status };
          if (p) body.baseUpdatedAt = p.updatedAt;
          var req = p ? CR.api('PATCH', '/admin/board/' + encodeURIComponent(p.id), body) : CR.api('POST', '/admin/board', body);
          return req.then(function () {
            ui.toast(status === 'published' ? (x.startAt && x.startAt > Date.now() ? 'Scheduled. It shows on the website from ' + u.date(x.startAt, true) + '.' : 'Published on the website.') : status === 'archived' ? 'Archived.' : 'Draft saved.');
            load();
            return true;
          }).catch(function (e) { err.hidden = false; err.textContent = e.message; return false; });
        }

        var form = h('div.bd-edit',
          h('div.stack',
            h('div.grid2', ui.field('Kind', f.kind), ui.field('Coupon', f.coupon, 'offers: active or scheduled codes')),
            h('label.field', h('span', 'Title', titleCount), f.title),
            h('label.field', h('span', 'Text', bodyCount), f.body),
            h('div.grid2', ui.field('Link', f.linkSel, 'a page of this website'), ui.field('Link text', f.linkLabel)),
            f.linkOther,
            h('div.field', h('span', 'Image', h('small', { text: 'JPEG, PNG or WebP, up to 2 MB' })), imgBox),
            h('div.grid2', ui.field('Show from', f.start, 'India time; blank = when published'), ui.field('Show until', f.end, 'India time; blank = no end')),
            h('label.check', f.pinned, 'Pin to the top'),
            err),
          h('div.stack', h('p.muted.small', { text: 'Preview' }), prevBox));
        refresh();
        var actions = [{ label: 'Cancel', value: null }];
        if (p) {
          actions.unshift({ label: 'Delete', kind: 'danger', onClick: function () {
            return ui.confirm('Delete this post?', 'It disappears from the website at once. This cannot be undone.', 'Delete', true).then(function (ok) {
              if (!ok) return false;
              return CR.api('DELETE', '/admin/board/' + encodeURIComponent(p.id)).then(function () { ui.toast('Post deleted.'); load(); return true; });
            });
          } });
          if (p.status !== 'archived') actions.splice(1, 0, { label: 'Archive', onClick: function () { return save('archived'); } });
        }
        actions.push({ label: p && p.status === 'published' ? 'Save as draft' : 'Save draft', onClick: function () { return save('draft'); } });
        actions.push({ label: p && p.status === 'published' ? 'Save and keep published' : 'Publish', kind: 'primary', onClick: function () { return save('published'); } });
        ui.dialog({ title: p ? 'Edit post' : 'New post', body: form, wide: true, actions: actions });
      }

      load();
    },
  };
})();
