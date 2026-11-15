/* CoRoute web admin: Explore (v3.59, src/destinations.js + src/explore.js, docs/features_355/explore_v359.md).
   Three tabs:
     Destinations   add / edit / hide / delete places, photo upload (JPEG/PNG/WebP, EXIF stripped on the server), order
     Layout         headline, which sections the app shows and in what order, categories (rename, hide, re-order, add up
                    to 6 custom ones), featured destinations, rider route switches
     Rider routes   routes riders chose to share (opt-in): preview on a map, hide / show / delete
   Every call is MASTER_ADMIN only and audited server side. Text is always set as text. */
(function () {
  'use strict';
  var CR = window.CR;
  if (!CR) return;
  var h = CR.util.h, clear = CR.util.clear, date = CR.util.date;
  var api = CR.api, ui = CR.ui;
  var TILE = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
  var ATTR = '&copy; <a href="https://www.openstreetmap.org/copyright" rel="noreferrer noopener" target="_blank">OpenStreetMap</a> contributors';
  var SECTION_HELP = {
    featured: 'Destinations you pick, shown first as large cards.',
    rider_routes: 'Places with routes shared by real riders, most ridden first.',
    near_you: 'Every destination, nearest to the rider first (worked out on the phone).',
    categories: 'Chips to filter by kind of ride.',
    suggest: 'A card asking riders to suggest a place.'
  };
  var state = { tab: 'destinations' };
  var maps = [];
  function teardown() { maps.forEach(function (m) { try { m.remove(); } catch (e) { /* gone */ } }); maps = []; }

  function btn(text, onclick, kind) { return h('button.btn' + (kind ? '.btn--' + kind : ''), { type: 'button', text: text, onclick: onclick }); }
  function input(attrs) { return h('input', attrs); }

  // ================================================================ destinations
  function renderDestinations(body, data) {
    var cats = data.categories;
    var catLabel = {};
    (data.layout ? data.layout.categories : []).forEach(function (c) { catLabel[c.id] = c.label; });
    var counts = data.counts || {};
    var head = h('div.row', btn('Add destination', function () { editDialog(null, cats, catLabel).then(reload); }, 'primary'),
      h('span.muted.small', { text: data.destinations.length + ' places · distances are worked out on each rider\'s phone, never stored.' }));
    body.appendChild(head);
    if (!data.enabled) body.appendChild(h('div.banner', { text: 'DESTINATIONS_ENABLED is off on this server: the app shows an empty Explore list.' }));
    var tb = h('tbody');
    data.destinations.forEach(function (d) {
      var photo = h('div.xp-thumb', d.photo ? null : h('span', { text: 'No photo' }));
      if (d.photo) {
        api('GET', d.photo.url.replace(/^\/api/, ''), null, { raw: true }).then(function (r) { return r.blob(); }).then(function (b) {
          photo.appendChild(h('img', { src: URL.createObjectURL(b), alt: '' }));
        }).catch(function () { /* thumbnail is optional */ });
      }
      tb.appendChild(h('tr',
        h('td', photo),
        h('td', h('b', { text: d.name }), h('div.small.muted', { text: (d.region || '') + ' · ' + d.lat.toFixed(4) + ', ' + d.lng.toFixed(4) })),
        h('td', { text: catLabel[d.category] || d.category }),
        h('td.num', { text: String(d.order) }),
        h('td.num', { text: String(counts[d.id] || 0) }),
        h('td', d.active ? ui.chip('Shown', 'ok') : ui.chip('Hidden', '')),
        h('td.nowrap',
          btn('Edit', function () { editDialog(d, cats, catLabel).then(reload); }, 'sm'),
          btn(d.active ? 'Hide' : 'Show', function () { api('PATCH', '/admin/destinations/' + d.id, { active: !d.active }).then(reload).catch(function (e) { ui.toast(e.message, true); }); }, 'sm'),
          btn('Photo', function () { photoDialog(d).then(reload); }, 'sm'),
          btn('Delete', function () {
            ui.confirm('Delete ' + d.name + '?', 'The place and its photo are deleted. Rider routes to it stay stored but are no longer listed.', 'Delete', true).then(function (ok) {
              if (ok) api('DELETE', '/admin/destinations/' + d.id).then(reload).catch(function (e) { ui.toast(e.message, true); });
            });
          }, 'sm'))));
    });
    body.appendChild(h('div.table-wrap', h('table.table', h('thead', h('tr', h('th', { text: '' }), h('th', { text: 'Place' }), h('th', { text: 'Category' }), h('th.num', { text: 'Order' }), h('th.num', { text: 'Rider routes' }), h('th', { text: 'Status' }), h('th', { text: '' }))), tb)));
  }

  function editDialog(d, cats, catLabel) {
    var name = input({ type: 'text', maxlength: '60', value: d ? d.name : '', required: true });
    var region = input({ type: 'text', maxlength: '40', value: d ? d.region : '' });
    var lat = input({ type: 'number', step: '0.00001', value: d ? d.lat : '' });
    var lng = input({ type: 'number', step: '0.00001', value: d ? d.lng : '' });
    var cat = ui.select(cats.map(function (c) { return [c, catLabel[c] || c]; }), d ? d.category : cats[0]);
    var tags = h('div.row.xp-tags');
    cats.forEach(function (c) {
      var cb = input({ type: 'checkbox', value: c, checked: d && d.tags.indexOf(c) >= 0 });
      tags.appendChild(h('label.xp-tag', cb, h('span', { text: catLabel[c] || c })));
    });
    var desc = h('textarea', { maxlength: '160', rows: '3' });
    desc.value = d ? d.description : '';
    var order = input({ type: 'number', min: '0', max: '10000', step: '1', value: d ? d.order : 100 });
    var active = input({ type: 'checkbox', checked: d ? d.active : true });
    var pick = h('p.small.muted', { text: 'Tip: in a map app, long-press the place and copy its coordinates.' });
    var body = h('div.xp-form', ui.field('Name', name), ui.field('Region', region, 'State or area'),
      h('div.row', ui.field('Latitude', lat), ui.field('Longitude', lng)), pick,
      ui.field('Category', cat), ui.field('Also good for', tags, 'up to 3'),
      ui.field('Short description', desc, 'up to 160 characters, your own words'),
      h('div.row', ui.field('Order', order, 'lower shows first'), h('label.field', h('span', { text: 'Shown in the app' }), active)));
    return ui.dialog({
      title: d ? 'Edit ' + d.name : 'Add destination', body: body, wide: true,
      actions: [{ label: 'Cancel', value: null }, { label: d ? 'Save' : 'Add', kind: 'primary', onClick: function () {
        var payload = { name: name.value, region: region.value, lat: Number(lat.value), lng: Number(lng.value), category: cat.value,
          tags: Array.prototype.slice.call(tags.querySelectorAll('input:checked')).map(function (x) { return x.value; }),
          description: desc.value, order: Number(order.value) || 0, active: active.checked };
        return (d ? api('PATCH', '/admin/destinations/' + d.id, payload) : api('POST', '/admin/destinations', payload)).then(function () { ui.toast(d ? 'Saved' : 'Added'); return true; });
      } }]
    });
  }

  function photoDialog(d) {
    var file = input({ type: 'file', accept: 'image/jpeg,image/png,image/webp' });
    var note = h('p.small.muted', { text: 'Your own photo or one you have the rights to. Up to 2 MB; location data in the file is removed. Landscape works best.' });
    var actions = [{ label: 'Cancel', value: null }];
    if (d.photo) actions.push({ label: 'Remove photo', kind: 'danger', onClick: function () { return api('DELETE', '/admin/destinations/' + d.id + '/photo').then(function () { ui.toast('Photo removed'); return true; }); } });
    actions.push({ label: 'Upload', kind: 'primary', onClick: function () {
      var f = file.files && file.files[0];
      if (!f) throw new Error('Choose an image first.');
      return api('POST', '/admin/destinations/' + d.id + '/photo', f, { type: f.type || 'image/jpeg' }).then(function () { ui.toast('Photo saved'); return true; });
    } });
    return ui.dialog({ title: 'Photo for ' + d.name, body: h('div', file, note), actions: actions });
  }

  // ================================================================ layout
  function renderLayout(body, data) {
    var cfg = JSON.parse(JSON.stringify(data.layout));
    var destName = {};
    data.destinations.forEach(function (d) { destName[d.id] = d.name; });
    var headline = input({ type: 'text', maxlength: '60', value: cfg.headline });
    var subtitle = input({ type: 'text', maxlength: '120', value: cfg.subtitle });
    body.appendChild(h('div.card', h('h2', { text: 'Top of the Explore tab' }), ui.field('Headline', headline), ui.field('Subtitle', subtitle)));

    // sections: order + switch + title
    var secBox = h('div');
    function drawSections() {
      clear(secBox);
      cfg.sections.forEach(function (s, i) {
        var on = input({ type: 'checkbox', checked: s.enabled, onchange: function () { s.enabled = on.checked; } });
        var title = input({ type: 'text', maxlength: '60', value: s.title, oninput: function () { s.title = title.value; } });
        secBox.appendChild(h('div.xp-row',
          h('div.xp-move', btn('↑', function () { if (i > 0) { cfg.sections.splice(i - 1, 0, cfg.sections.splice(i, 1)[0]); drawSections(); } }, 'sm'),
            btn('↓', function () { if (i < cfg.sections.length - 1) { cfg.sections.splice(i + 1, 0, cfg.sections.splice(i, 1)[0]); drawSections(); } }, 'sm')),
          h('label.xp-switch', on, h('span', { text: 'Show' })), title, h('span.small.muted', { text: SECTION_HELP[s.id] || s.id })));
      });
    }
    drawSections();
    body.appendChild(h('div.card', h('h2', { text: 'Sections, top to bottom' }), secBox));

    // categories
    var catBox = h('div');
    function drawCats() {
      clear(catBox);
      cfg.categories.forEach(function (c, i) {
        var on = input({ type: 'checkbox', checked: c.enabled, onchange: function () { c.enabled = on.checked; } });
        var label = input({ type: 'text', maxlength: '24', value: c.label, oninput: function () { c.label = label.value; } });
        catBox.appendChild(h('div.xp-row',
          h('div.xp-move', btn('↑', function () { if (i > 0) { cfg.categories.splice(i - 1, 0, cfg.categories.splice(i, 1)[0]); drawCats(); } }, 'sm'),
            btn('↓', function () { if (i < cfg.categories.length - 1) { cfg.categories.splice(i + 1, 0, cfg.categories.splice(i, 1)[0]); drawCats(); } }, 'sm')),
          h('label.xp-switch', on, h('span', { text: 'Show' })), label, h('code.small', { text: c.id }),
          c.builtin ? h('span.small.muted', { text: 'built-in' }) : btn('Remove', function () { cfg.categories.splice(i, 1); drawCats(); }, 'sm')));
      });
    }
    drawCats();
    var newId = input({ type: 'text', placeholder: 'id, e.g. coffee_runs', maxlength: '24', pattern: '[a-z][a-z0-9_]{1,23}' });
    var newLabel = input({ type: 'text', placeholder: 'Label, e.g. Coffee runs', maxlength: '24' });
    body.appendChild(h('div.card', h('h2', { text: 'Categories' }),
      h('p.small.muted', { text: 'Hiding a category also hides its destinations in the app. A category still used by a destination cannot be removed.' }),
      catBox, h('div.row.xp-add', newId, newLabel, btn('Add category', function () {
        var id = newId.value.trim();
        if (!/^[a-z][a-z0-9_]{1,23}$/.test(id)) { ui.toast('Use lowercase letters, digits and _ for the id.', true); return; }
        if (cfg.categories.some(function (c) { return c.id === id; })) { ui.toast('That id exists.', true); return; }
        cfg.categories.push({ id: id, label: newLabel.value.trim() || id, enabled: true, builtin: false });
        newId.value = ''; newLabel.value = ''; drawCats();
      }))));

    // featured
    var featBox = h('div');
    function drawFeatured() {
      clear(featBox);
      if (!cfg.featured.length) featBox.appendChild(h('p.small.muted', { text: 'None yet: the Featured section is left out until you pick places.' }));
      cfg.featured.forEach(function (id, i) {
        featBox.appendChild(h('div.xp-row', h('b', { text: destName[id] || id }),
          btn('↑', function () { if (i > 0) { cfg.featured.splice(i - 1, 0, cfg.featured.splice(i, 1)[0]); drawFeatured(); } }, 'sm'),
          btn('Remove', function () { cfg.featured.splice(i, 1); drawFeatured(); }, 'sm')));
      });
    }
    drawFeatured();
    var addSel = ui.select([['', 'Add a destination…']].concat(data.destinations.filter(function (d) { return d.active; }).map(function (d) { return [d.id, d.name]; })), '');
    addSel.addEventListener('change', function () {
      if (addSel.value && cfg.featured.indexOf(addSel.value) < 0 && cfg.featured.length < 12) { cfg.featured.push(addSel.value); drawFeatured(); }
      addSel.value = '';
    });
    body.appendChild(h('div.card', h('h2', { text: 'Featured destinations' }), featBox, addSel));

    // routes
    var routesOn = input({ type: 'checkbox', checked: cfg.routes.enabled });
    var notesOn = input({ type: 'checkbox', checked: cfg.routes.showNotes });
    body.appendChild(h('div.card', h('h2', { text: 'Rider routes' }),
      data.routesFlag ? null : h('div.banner', { text: 'The "Explore rider routes" feature switch is off in the app admin: nothing is shared or shown until it is on.' }),
      h('label.xp-switch', routesOn, h('span', { text: 'Riders can share routes and see others\' routes' })),
      h('label.xp-switch', notesOn, h('span', { text: 'Show riders\' short notes with their routes' })),
      h('p.small.muted', { text: 'Sharing is always the rider\'s choice after a ride. The first and last kilometre are left out, the time of day is not stored, and riders can delete their routes at any time.' })));

    body.appendChild(h('div.row.xp-save', btn('Save layout', function () {
      cfg.headline = headline.value; cfg.subtitle = subtitle.value;
      cfg.routes = { enabled: routesOn.checked, showNotes: notesOn.checked };
      api('PUT', '/admin/explore/config', cfg).then(function () { ui.toast('Explore layout saved. Riders see it within a few minutes.'); reload(); })
        .catch(function (e) { ui.toast(e.message, true); });
    }, 'primary')));
  }

  // ================================================================ rider routes
  function renderRoutes(body, data) {
    var destName = {};
    data.destinations.forEach(function (d) { destName[d.id] = d.name; });
    var status = ui.select([['', 'All'], ['live', 'Shown'], ['hidden', 'Hidden']], state.rstatus || '');
    var dest = ui.select([['', 'All destinations']].concat(data.destinations.map(function (d) { return [d.id, d.name]; })), state.rdest || '');
    var list = h('div', ui.loading());
    var mapBox = h('div.intel-map.xp-map', { role: 'region', 'aria-label': 'Route preview map' });
    body.appendChild(h('div.toolbar', ui.field('Status', status), ui.field('Destination', dest)));
    body.appendChild(h('div.card', mapBox, h('p.muted.small', { text: 'Select a route to preview it. Map tiles: OpenStreetMap (admin use only, low volume).' })));
    body.appendChild(list);
    var map = null, line = null;
    if (window.L) {
      map = window.L.map(mapBox, { scrollWheelZoom: false }).setView([12.97, 77.59], 7);
      window.L.tileLayer(TILE, { maxZoom: 18, minZoom: 3, attribution: ATTR }).addTo(map);
      maps.push(map);
      setTimeout(function () { try { map.invalidateSize(); } catch (e) { /* gone */ } }, 50);
    } else mapBox.appendChild(h('div.banner', { text: 'The map library did not load.' }));
    function show(r) {
      if (!map) return;
      if (line) line.remove();
      line = window.L.polyline(r.points, { color: '#2B7A8C', weight: 4 }).addTo(map);
      map.fitBounds(line.getBounds(), { padding: [20, 20] });
    }
    function load() {
      state.rstatus = status.value; state.rdest = dest.value;
      var qs = '?status=' + encodeURIComponent(status.value) + '&destId=' + encodeURIComponent(dest.value);
      api('GET', '/admin/explore/routes' + qs).then(function (r) {
        clear(list);
        if (!r.routes.length) { list.appendChild(h('div.card', h('p.empty', { text: 'No shared routes here yet.' }))); return; }
        var tb = h('tbody');
        r.routes.forEach(function (x) {
          tb.appendChild(h('tr.is-link', { onclick: function () { show(x); } },
            h('td', h('b', { text: '@' + x.username }), h('div.small.muted', { text: x.day })),
            h('td', { text: destName[x.destId] || x.destId }),
            h('td.num', { text: x.distanceKm + ' km' }),
            h('td.num', { text: x.durationMin ? Math.floor(x.durationMin / 60) + ' h ' + (x.durationMin % 60) + ' min' : '-' }),
            h('td', { text: x.note || '' }),
            h('td', x.status === 'live' ? ui.chip('Shown', 'ok') : ui.chip('Hidden', 'warn')),
            h('td.nowrap',
              btn(x.status === 'live' ? 'Hide' : 'Show', function (e) {
                e.stopPropagation();
                api('PATCH', '/admin/explore/routes/' + x.id, { status: x.status === 'live' ? 'hidden' : 'live' }).then(load).catch(function (er) { ui.toast(er.message, true); });
              }, 'sm'),
              btn('Delete', function (e) {
                e.stopPropagation();
                ui.confirm('Delete this route?', 'The route by @' + x.username + ' is deleted for good.', 'Delete', true).then(function (ok) {
                  if (ok) api('DELETE', '/admin/explore/routes/' + x.id).then(load).catch(function (er) { ui.toast(er.message, true); });
                });
              }, 'sm'))));
        });
        list.appendChild(h('div.table-wrap', h('table.table', h('thead', h('tr', h('th', { text: 'Rider' }), h('th', { text: 'Destination' }), h('th.num', { text: 'Distance' }), h('th.num', { text: 'Riding time' }), h('th', { text: 'Note' }), h('th', { text: 'Status' }), h('th', { text: '' }))), tb)));
        show(r.routes[0]);
      }).catch(function (e) { clear(list).appendChild(ui.error(e)); });
    }
    status.addEventListener('change', load);
    dest.addEventListener('change', load);
    load();
  }

  // ================================================================ page
  var viewEl = null;
  function reload() { if (viewEl) render(viewEl); }
  function render(view) {
    teardown();
    viewEl = view;
    clear(view);
    view.appendChild(ui.pageHead('Explore', 'What riders see in the app\'s Explore tab: the places, the layout, and the routes riders chose to share.'));
    var tabs = h('div.row', { role: 'tablist', 'aria-label': 'Explore' });
    [['destinations', 'Destinations'], ['layout', 'Layout & categories'], ['routes', 'Rider routes']].forEach(function (t) {
      tabs.appendChild(h('button.btn.btn--sm' + (state.tab === t[0] ? '.is-on' : ''), { type: 'button', role: 'tab', 'aria-selected': String(state.tab === t[0]), text: t[1],
        onclick: function () { state.tab = t[0]; render(view); } }));
    });
    view.appendChild(tabs);
    var body = h('div.xp-body', ui.loading());
    view.appendChild(body);
    Promise.all([api('GET', '/admin/destinations'), api('GET', '/admin/explore/config')]).then(function (rs) {
      var data = { destinations: rs[0].destinations, categories: rs[0].categories, enabled: rs[0].enabled, layout: rs[1].config, counts: rs[1].counts, routesFlag: rs[1].routesFlag };
      clear(body);
      if (state.tab === 'destinations') renderDestinations(body, data);
      else if (state.tab === 'layout') renderLayout(body, data);
      else renderRoutes(body, data);
    }).catch(function (e) { clear(body).appendChild(ui.error(e)); });
  }

  CR.sections.explore = { title: 'Explore', render: render, teardown: teardown };
})();
