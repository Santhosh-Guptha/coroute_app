/* 3.56 /signin: the CoRoute account of the app on the website.
 * POST /api/auth/login { identifier, password } (rate limited per IP and per account on the server), or
 * Google Identity Services -> POST /api/auth/google { idToken } when GET /api/web/config names a web client id.
 * The token goes to sessionStorage (CoShop.setToken), never into the URL. A temporary password (admin reset)
 * asks for a new one first (POST /api/me/password). Then back to ?next= (only /plans, /account, /receipt, /trip/<id> and the operator pages). */
(function () {
  'use strict';
  var S = window.CoShop;
  if (!S) return;
  var form = S.$('si-form');
  if (!form) return;
  var next = S.safeNext(S.query('next'));
  var status = S.$('si-status');
  var submit = S.$('si-submit');

  function notice(text, kind) {
    var n = S.$('si-notice');
    n.textContent = text;
    n.className = 'sh-notice' + (kind ? ' sh-notice--' + kind : '');
    n.hidden = !text;
  }
  function say(node, text) { node.textContent = text || ''; }
  function go() { window.location.replace(next); }

  // After a session: the temporary-password step, or straight on.
  function signedIn(json) {
    if (!json || !json.token) { say(status, 'Sign in did not complete. Try again.'); return; }
    S.setToken(json.token);
    if (!S.token()) { say(status, 'This browser blocks session storage, so you cannot stay signed in. Allow site data for this site, or use another browser.'); return; }
    if (json.user && json.user.mustChangePassword) {
      form.hidden = true;
      S.$('si-change').hidden = false;
      S.$('si-new').focus();
      return;
    }
    go();
  }

  if (S.query('out')) notice('You are signed out.', 'ok');
  if (S.query('expired')) notice('Your session ended. Sign in again to continue.', 'warn');
  if (/^\/plans/.test(next) && !S.query('out')) notice('Sign in to see your price and pay. Your plan reaches the app on its own.', '');

  // Already signed in in this tab: say who, offer the way on.
  if (S.token()) {
    S.api('GET', '/me').then(function (r) {
      if (!r.ok) return;
      form.hidden = true;
      var who = r.json.username ? '@' + r.json.username : (r.json.name || 'your account');
      say(S.$('si-already-who'), 'Signed in as ' + who + '.');
      S.$('si-already').hidden = false;
    });
  }

  form.addEventListener('submit', function (e) {
    e.preventDefault();
    var id = S.$('si-id').value.trim();
    var pw = S.$('si-pw').value;
    if (!id) { say(status, 'Enter your email or callsign.'); S.$('si-id').focus(); return; }
    if (!pw) { say(status, 'Enter your password.'); S.$('si-pw').focus(); return; }
    say(status, '');
    submit.disabled = true;
    submit.textContent = 'Signing in…';
    S.api('POST', '/auth/login', { identifier: id, password: pw }, { auth: false }).then(function (r) {
      submit.disabled = false;
      submit.textContent = 'Sign in';
      if (!r.ok) {
        say(status, r.status === 401 ? 'That email, callsign or password is not right.' : (r.json.error || 'Could not sign in. Try again.'));
        return;
      }
      S.$('si-pw').value = '';
      signedIn(r.json);
    });
  });

  S.$('si-change').addEventListener('submit', function (e) {
    e.preventDefault();
    var a = S.$('si-new').value;
    var b = S.$('si-new2').value;
    var st = S.$('si-change-status');
    if (a.length < 8) { say(st, 'Use at least 8 characters.'); return; }
    if (a !== b) { say(st, 'The two passwords are not the same.'); return; }
    S.api('POST', '/me/password', { newPassword: a }).then(function (r) {
      if (!r.ok) { say(st, r.json.error || 'Could not save the new password.'); return; }
      if (r.json.token) S.setToken(r.json.token);
      go();
    });
  });

  var forgot = S.$('si-forgot');
  forgot.addEventListener('click', function () {
    var box = S.$('si-forgot-box');
    box.hidden = !box.hidden;
    forgot.setAttribute('aria-expanded', box.hidden ? 'false' : 'true');
  });

  // Support address and Google button from the server's public config.
  S.api('GET', '/web/config', undefined, { auth: false }).then(function (r) {
    if (!r.ok) return;
    var mail = String(r.json.supportEmail || '');
    if (/^[^\s@<>"']+@[^\s@<>"']+\.[a-z]{2,}$/i.test(mail)) {
      var a = S.$('si-support');
      a.setAttribute('href', 'mailto:' + mail);
      a.textContent = mail;
    }
    var cid = String(r.json.googleClientId || '');
    if (!/^[0-9]+-[a-z0-9]+\.apps\.googleusercontent\.com$/.test(cid)) return;
    var s = document.createElement('script');
    s.src = 'https://accounts.google.com/gsi/client';
    s.async = true;
    s.onload = function () {
      var g = window.google && window.google.accounts && window.google.accounts.id;
      if (!g) return;
      g.initialize({
        client_id: cid,
        ux_mode: 'popup',
        callback: function (resp) {
          if (!resp || !resp.credential) return;
          say(status, 'Signing in with Google…');
          S.api('POST', '/auth/google', { idToken: resp.credential }, { auth: false }).then(function (res) {
            if (!res.ok) { say(status, res.json.error || 'Google sign-in did not work. Try your password instead.'); return; }
            say(status, '');
            signedIn(res.json);
          });
        }
      });
      var box = S.$('si-google');
      var dark = document.documentElement.getAttribute('data-theme') === 'dark' ||
        (!document.documentElement.getAttribute('data-theme') && window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches);
      g.renderButton(box, { type: 'standard', theme: dark ? 'filled_black' : 'outline', size: 'large', text: 'signin_with', shape: 'pill', width: Math.min(box.clientWidth || 320, 400) });
      box.hidden = false;
      S.$('si-google-wrap').hidden = false;
    };
    document.head.appendChild(s);
  });
})();
