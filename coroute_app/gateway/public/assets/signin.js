/* 3.56 /signin: the CoRoute account of the app on the website.
 * 3.57: the server sets an httpOnly refresh cookie at sign-in (this script never sees it); a tab opened later is
 * signed in silently through it; 2-step codes for accounts that use them; "Forgot password?" mails a single-use
 * link (#reset=<token>, read here and removed from the address bar at once).
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

  var mfaToken = null;
  var mfaEmail = false;
  // Only one panel of the card at a time.
  var PANELS = ['si-form', 'si-mfa', 'si-lock', 'si-register', 'si-inbox', 'si-reset', 'si-change', 'si-already'];
  function show(id) {
    PANELS.forEach(function (p) { var n = S.$(p); if (n) n.hidden = p !== id; });
    // A long form (create account) leaves the page scrolled: bring the new, shorter panel into view.
    var card = S.$(id) && S.$(id).closest('.sh-card');
    if (card && card.getBoundingClientRect().top < 0) { try { card.scrollIntoView({ block: 'start' }); } catch (e) { window.scrollTo(0, 0); } }
  }
  // After a session: the 2-step code, the temporary-password step, or straight on.
  function signedIn(json) {
    if (json && json.mfa === 'verify' && json.mfaToken) {
      mfaToken = json.mfaToken;
      var methods = Array.isArray(json.methods) ? json.methods : ['totp', 'recovery'];
      S.$('si-mfa-email-wrap').hidden = methods.indexOf('email') < 0;
      S.$('si-mfa-rc').parentNode.hidden = methods.indexOf('recovery') < 0;
      show('si-mfa');
      S.$('si-mfa-code').focus();
      return;
    }
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

  if (S.query('emailChanged')) notice('Your e-mail address was changed. Sign in with the new address.', 'ok');
  else if (S.query('out')) notice('You are signed out.', 'ok');
  if (S.query('expired') === 'idle') notice('You were signed out after 60 minutes without activity. Sign in again to continue.', 'warn');
  else if (S.query('expired')) notice('You were signed out. Sign in again to continue.', 'warn');
  if (/^\/plans/.test(next) && !S.query('out') && !S.query('expired')) notice('Sign in to see your price and pay. Your plan reaches the app on its own.', '');

  // Round 4 sign-up link: #verify=<token> (read and removed from the address bar at once).
  var vm = /^#verify=([A-Za-z0-9_-]{40,60})$/.exec(window.location.hash || '');
  if (vm) {
    try { window.history.replaceState(null, '', window.location.pathname + window.location.search); } catch (e) { /* ignore */ }
    S.api('POST', '/auth/email/verify', { token: vm[1] }, { auth: false }).then(function (r) {
      if (r.ok) notice(r.json.message || 'Your e-mail is confirmed. Sign in to start riding.', 'ok');
      else notice(r.json.error || 'This link is not valid any more. Sign up again or ask for a new link.', 'warn');
      if (r.ok && r.json.email) S.$('si-id').value = r.json.email;
    });
  }

  // 3.57 reset link: #reset=<token> (a fragment never reaches a server log or a Referer).
  var resetToken = '';
  var m = /^#reset=([A-Za-z0-9_-]{40,60})$/.exec(window.location.hash || '');
  if (m) {
    resetToken = m[1];
    try { window.history.replaceState(null, '', window.location.pathname + window.location.search); } catch (e) { /* ignore */ }
    form.hidden = true;
    S.$('si-reset').hidden = false;
    S.$('si-reset-pw').focus();
  }

  // A tab opened later (no session in this tab yet): signed in silently through the httpOnly cookie, if it is
  // still valid. Never after "signed out" or "expired", never while a reset link is open.
  if (!S.token() && !resetToken && !S.query('out') && !S.query('expired')) {
    S.refresh().then(function (ok) { if (ok && S.query('next')) go(); else if (ok) showAlready(); });
  }

  function showAlready() {
    S.api('GET', '/me', undefined, { noRedirect: true }).then(function (r) {
      if (!r.ok) return;
      form.hidden = true;
      var who = r.json.username ? '@' + r.json.username : (r.json.name || 'your account');
      say(S.$('si-already-who'), 'Signed in as ' + who + '.');
      S.$('si-already').hidden = false;
    });
  }

  // Already signed in in this tab: say who, offer the way on.
  if (S.token() && !resetToken) showAlready();

  form.addEventListener('submit', function (e) {
    e.preventDefault();
    var id = S.$('si-id').value.trim();
    var pw = S.$('si-pw').value;
    if (!id) { say(status, 'Enter your email or callsign.'); S.$('si-id').focus(); return; }
    if (!pw) { say(status, 'Enter your password.'); S.$('si-pw').focus(); return; }
    say(status, '');
    submit.disabled = true;
    submit.textContent = 'Signing in…';
    S.api('POST', '/auth/login', { identifier: id, password: pw, client: 'web' }, { auth: false }).then(function (r) {
      submit.disabled = false;
      submit.textContent = 'Sign in';
      if (!r.ok) {
        if (rideLocked(r)) return;
        if (r.json.code === 'EMAIL_NOT_VERIFIED') { unverified(r.json.email || (id.indexOf('@') > 0 ? id : '')); return; }
        say(status, r.status === 401 ? 'That email, callsign or password is not right.' : r.status === 429 ? 'Too many attempts. Wait a few minutes, or reset your password.' : (r.json.error || 'Could not sign in. Try again.'));
        return;
      }
      S.$('si-pw').value = '';
      signedIn(r.json);
    });
  });

  // ---- Round 4 ride lock: 423 RIDE_ACTIVE_ELSEWHERE -> "Send code to my e-mail" ----
  var lockToken = '';
  var lockTimer = null;
  function rideLocked(r) {
    if (r.status !== 423 || r.json.code !== 'RIDE_ACTIVE_ELSEWHERE' || !r.json.lockToken) return false;
    lockToken = r.json.lockToken;
    S.$('si-pw').value = '';
    say(S.$('si-lock-title'), "You're on a ride on " + (r.json.device || 'another phone'));
    // The title already names the phone: the panel keeps only what to do ("End the ride on that phone ...").
    say(S.$('si-lock-msg'), String(r.json.error || '').replace(/^You're on a ride on [^.]*\.\s*/, '') || 'End the ride on that phone to sign in here.');
    say(S.$('si-lock-status'), '');
    S.$('si-lock-codebox').hidden = true;
    S.$('si-lock-send').hidden = false;
    S.$('si-lock-verify').hidden = true;
    show('si-lock');
    S.$('si-lock-send').focus();
    return true;
  }
  function countdown(btn, secs, label) {
    if (lockTimer) clearInterval(lockTimer);
    var left = Math.max(0, secs | 0);
    function tick() {
      btn.disabled = left > 0;
      btn.textContent = left > 0 ? 'Send again in ' + left + ' s' : label;
      if (left <= 0 && lockTimer) { clearInterval(lockTimer); lockTimer = null; }
      left--;
    }
    tick();
    lockTimer = setInterval(tick, 1000);
  }
  function sendLockCode() {
    var st = S.$('si-lock-status');
    say(st, '');
    S.$('si-lock-send').disabled = true;
    S.api('POST', '/auth/ride-lock/code', { lockToken: lockToken }, { auth: false }).then(function (r) {
      S.$('si-lock-send').disabled = false;
      if (!r.ok) {
        if (r.json.code === 'LOCK_EXPIRED') { show('si-form'); say(status, 'That took too long. Sign in again.'); return; }
        say(st, r.json.error || 'Could not send the code. Try again.');
        if (r.json.retryAfterSec) countdown(S.$('si-lock-resend'), r.json.retryAfterSec, 'Send code again');
        return;
      }
      say(S.$('si-lock-sent'), 'We sent a 6-digit code to ' + (r.json.sentTo || 'your e-mail address') + '. It works for 10 minutes.');
      S.$('si-lock-codebox').hidden = false;
      S.$('si-lock-send').hidden = true;
      S.$('si-lock-verify').hidden = false;
      countdown(S.$('si-lock-resend'), r.json.resendAfterSec || 60, 'Send code again');
      S.$('si-lock-code').focus();
    });
  }
  S.$('si-lock-send').addEventListener('click', sendLockCode);
  S.$('si-lock-resend').addEventListener('click', sendLockCode);
  S.$('si-lock-back').addEventListener('click', function () { if (lockTimer) clearInterval(lockTimer); lockToken = ''; show('si-form'); S.$('si-id').focus(); });
  S.$('si-lock').addEventListener('submit', function (e) {
    e.preventDefault();
    var v = S.$('si-lock-code').value.replace(/[\s-]+/g, '');
    var st = S.$('si-lock-status');
    if (!/^\d{6}$/.test(v)) { say(st, 'Enter the 6-digit code from the e-mail.'); return; }
    S.$('si-lock-verify').disabled = true;
    S.api('POST', '/auth/ride-lock/verify', { lockToken: lockToken, code: v, client: 'web' }, { auth: false }).then(function (r) {
      S.$('si-lock-verify').disabled = false;
      if (!r.ok) {
        if (r.json.code === 'LOCK_EXPIRED') { show('si-form'); say(status, 'That took too long. Sign in again.'); return; }
        say(st, r.json.error || 'That code did not work.');
        return;
      }
      if (lockTimer) clearInterval(lockTimer);
      signedIn(r.json);
    });
  });

  // ---- Round 4: address not confirmed yet ----
  function unverified(email) {
    say(status, 'Confirm your e-mail first: open the link we sent you.');
    if (!email) return;
    var b = document.createElement('button');
    b.type = 'button';
    b.className = 'sh-linkbtn';
    b.textContent = 'Send a new link';
    b.addEventListener('click', function () {
      b.disabled = true;
      S.api('POST', '/auth/register/resend', { email: email }, { auth: false }).then(function (r) { say(status, r.json.message || 'If this address is waiting for confirmation, we sent a new link.'); });
    });
    status.appendChild(document.createTextNode(' '));
    status.appendChild(b);
  }

  // ---- Round 4: create an account -> "Check your inbox" ----
  var regEmail = '';
  S.$('si-to-register').addEventListener('click', function () { show('si-register'); S.$('rg-name').focus(); });
  S.$('rg-back').addEventListener('click', function () { show('si-form'); S.$('si-id').focus(); });
  S.$('rg-pillion').addEventListener('change', function () { S.$('rg-bike').disabled = this.checked; });
  S.$('si-register').addEventListener('submit', function (e) {
    e.preventDefault();
    var st = S.$('rg-status');
    var v = function (id) { return S.$(id).value.trim(); };
    var pillion = S.$('rg-pillion').checked;
    if (v('rg-name').length < 2) { say(st, 'Enter your name or callsign.'); return; }
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(v('rg-email'))) { say(st, 'Enter a valid e-mail address.'); return; }
    if (v('rg-phone').length < 7) { say(st, 'Enter your mobile number so your group can call you.'); return; }
    if (S.$('rg-pw').value.length < 8) { say(st, 'Use at least 8 characters for the password.'); return; }
    if (S.$('rg-pw').value !== S.$('rg-pw2').value) { say(st, 'The two passwords are not the same.'); return; }
    if (!pillion && v('rg-bike').length < 3) { say(st, 'Enter your bike number, or tick pillion.'); return; }
    if (v('rg-ice-name').length < 2 || v('rg-ice-phone').length < 7) { say(st, 'Enter the name and phone number of your emergency contact.'); return; }
    if (!S.$('rg-terms').checked) { say(st, 'Please accept the Terms and Privacy Policy.'); return; }
    say(st, '');
    var btn = S.$('rg-submit');
    btn.disabled = true;
    btn.textContent = 'Creating account…';
    S.api('POST', '/auth/register', {
      name: v('rg-name'), email: v('rg-email'), phone: v('rg-phone'), password: S.$('rg-pw').value,
      vehicleType: pillion ? 'Pillion Rider' : 'Motorcycle', vehicleNo: pillion ? 'PILLION' : v('rg-bike'),
      emergencyContactName: v('rg-ice-name'), emergencyContact: v('rg-ice-phone'), client: 'web'
    }, { auth: false }).then(function (r) {
      btn.disabled = false;
      btn.textContent = 'Create account';
      if (r.status === 202 || (r.json && r.json.pending)) {
        regEmail = v('rg-email');
        S.$('rg-pw').value = ''; S.$('rg-pw2').value = '';
        say(S.$('si-inbox-msg'), (r.json.message || 'Check your e-mail to finish creating your account') + '. We sent a link to ' + regEmail + '.');
        say(S.$('si-inbox-status'), '');
        show('si-inbox');
        countdown(S.$('si-inbox-resend'), r.json.resendAfterSec || 60, 'Send a new link');
        return;
      }
      if (r.ok && r.json.token) { signedIn(r.json); return; } // an older gateway signs in at once
      say(st, r.json.error || 'Could not create the account. Try again.');
    });
  });
  S.$('si-inbox-resend').addEventListener('click', function () {
    var btn = this;
    btn.disabled = true;
    S.api('POST', '/auth/register/resend', { email: regEmail }, { auth: false }).then(function (r) {
      say(S.$('si-inbox-status'), r.status === 429 ? 'Too many requests. Try again later.' : (r.json.message || 'If this address is waiting for confirmation, we sent a new link.'));
      countdown(btn, (r.json && r.json.resendAfterSec) || 60, 'Send a new link');
    });
  });
  S.$('si-inbox-back').addEventListener('click', function () {
    if (lockTimer) clearInterval(lockTimer);
    show('si-form');
    if (regEmail) S.$('si-id').value = regEmail;
    S.$('si-pw').focus();
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

  // 2-step code (or a recovery code).
  var useRc = false;
  S.$('si-mfa-rc').addEventListener('click', function () {
    useRc = !useRc;
    var inp = S.$('si-mfa-code');
    inp.value = '';
    inp.setAttribute('inputmode', useRc ? 'text' : 'numeric');
    inp.setAttribute('maxlength', useRc ? '11' : '7');
    S.$('si-mfa-code').previousElementSibling.textContent = useRc ? 'Recovery code' : '6-digit code';
    this.textContent = useRc ? 'Use the 6-digit code instead' : 'Use a recovery code instead';
    inp.focus();
  });
  // Round 4: an e-mailed code (operators without an authenticator app; never administrators).
  S.$('si-mfa-email').addEventListener('click', function () {
    var btn = this;
    var st = S.$('si-mfa-status');
    btn.disabled = true;
    S.api('POST', '/auth/mfa/email-code', { mfaToken: mfaToken }, { auth: false }).then(function (r) {
      btn.disabled = false;
      if (!r.ok) { say(st, r.json.error || 'Could not send the code.'); return; }
      mfaEmail = true; useRc = false;
      S.$('si-mfa-code').previousElementSibling.textContent = 'Code from the e-mail';
      say(st, '');
      btn.textContent = 'Send another e-mail code';
      S.$('si-mfa-code').focus();
    });
  });
  S.$('si-mfa').addEventListener('submit', function (e) {
    e.preventDefault();
    var v = S.$('si-mfa-code').value.trim();
    var st = S.$('si-mfa-status');
    if (!v) { say(st, 'Enter the code.'); return; }
    var body = useRc ? { mfaToken: mfaToken, recoveryCode: v, client: 'web' }
      : mfaEmail ? { mfaToken: mfaToken, emailCode: v.replace(/\s+/g, ''), client: 'web' }
        : { mfaToken: mfaToken, code: v.replace(/\s+/g, ''), client: 'web' };
    S.api('POST', '/auth/mfa/verify', body, { auth: false }).then(function (r) {
      if (!r.ok) {
        if (r.json.code === 'MFA_EXPIRED') { show('si-form'); say(status, 'That took too long. Sign in again.'); return; }
        if (rideLocked(r)) return;
        say(st, r.json.error || 'That code is not right.');
        return;
      }
      signedIn(r.json);
    });
  });

  // Reset by e-mail link.
  S.$('si-reset').addEventListener('submit', function (e) {
    e.preventDefault();
    var a = S.$('si-reset-pw').value;
    var b = S.$('si-reset-pw2').value;
    var st = S.$('si-reset-status');
    if (a.length < 8) { say(st, 'Use at least 8 characters.'); return; }
    if (a !== b) { say(st, 'The two passwords are not the same.'); return; }
    S.api('POST', '/auth/password/reset', { token: resetToken, newPassword: a }, { auth: false }).then(function (r) {
      if (!r.ok) { say(st, r.json.error || 'Could not save the new password.'); return; }
      resetToken = '';
      S.$('si-reset').hidden = true;
      form.hidden = false;
      notice('Your password was changed and every device was signed out. Sign in with the new password.', 'ok');
      S.$('si-id').focus();
    });
  });

  var forgot = S.$('si-forgot');
  S.$('si-forgot-send').addEventListener('click', function () {
    var email = S.$('si-forgot-email').value.trim();
    var st = S.$('si-forgot-status');
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) { say(st, 'Enter the e-mail address of your account.'); return; }
    this.disabled = true;
    var btn = this;
    S.api('POST', '/auth/password/forgot', { email: email }, { auth: false }).then(function (r) {
      btn.disabled = false;
      say(st, r.status === 429 ? 'Too many requests. Try again later.' : (r.json.message || 'If an account uses this address, we sent it a link.'));
    });
  });
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
          S.api('POST', '/auth/google', { idToken: resp.credential, client: 'web' }, { auth: false }).then(function (res) {
            if (!res.ok && rideLocked(res)) return;
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
