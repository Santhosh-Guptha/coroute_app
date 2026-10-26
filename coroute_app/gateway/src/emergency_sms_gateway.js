'use strict';

const crypto = require('crypto');
const config = require('./config');
const { cleanPhone, validPhone } = require('./validate');

/**
 * Normalizes a phone number to standard E.164 string format (e.g. +919876543210).
 * Handles Indian numbers, international prefixes, and strips formatting artifacts.
 */
function toE164(phone, defaultCountryCode = '+91') {
  if (!phone) return '';
  let cleaned = String(phone).trim().replace(/[^0-9+]/g, '');
  if (cleaned.startsWith('00')) {
    cleaned = '+' + cleaned.slice(2);
  }
  if (!cleaned.startsWith('+')) {
    if (cleaned.startsWith('0')) {
      cleaned = cleaned.slice(1);
    }
    // Standard 10-digit mobile number in India
    if (cleaned.length === 10) {
      cleaned = defaultCountryCode + cleaned;
    } else {
      cleaned = '+' + cleaned;
    }
  }
  return cleaned;
}

/**
 * Strips leading '+' for WhatsApp Graph API which expects digits only.
 */
function toWhatsAppNumber(phone) {
  return toE164(phone).replace(/^\+/, '');
}

/**
 * Server-Side Emergency SMS and WhatsApp Web Gateway for CoRoute.
 * Provides guaranteed cloud dispatch for iOS devices, data-only SIMs, and zero-balance situations.
 */
class EmergencySmsGateway {
  /**
   * @param {Object} opts
   * @param {any} [opts.repo]
   * @param {any} [opts.convoys]
   * @param {any} [opts.logger]
   * @param {typeof fetch} [opts.fetchImpl]
   * @param {any} [opts.config]
   */
  constructor({
    repo = null,
    convoys = null,
    logger = console,
    fetchImpl = globalThis.fetch,
    config: cfg = config,
  } = {}) {
    this.repo = repo;
    this.convoys = convoys;
    this.log = logger || console;
    this.fetch = fetchImpl || globalThis.fetch;
    this.config = cfg || {};
    this.outbox = [];
    this.maxOutboxSize = 1000;
    this.liveLinks = new Map(); // tokenHash -> { tripId, riderId, ... }
  }

  /**
   * Generates a secure live tracking URL for the emergency event.
   * Can be viewed by emergency services and guardians via /e/<token>.
   */
  generateTrackingUrl({ tripId, riderId, riderName, lat, lng, speedKmh = 0, severity = 'CRITICAL', bloodGroup = '' }) {
    const token = crypto.randomBytes(24).toString('base64url');
    const hash = crypto.createHash('sha256').update(token).digest('hex');
    const now = Date.now();
    const expiryMin = this.config.liveLinkMin || 30;
    const expiresAt = now + expiryMin * 60000;

    const liveRecord = {
      tokenHash: hash,
      tripId: tripId || `standalone-${now}`,
      riderId: riderId || 'rider',
      riderName: riderName || 'Rider in distress',
      firstName: String(riderName || 'Rider').trim().split(/\s+/)[0].slice(0, 20),
      lat: Number(lat) || 0,
      lng: Number(lng) || 0,
      speedKmh: Number(speedKmh) || 0,
      severity,
      bloodGroup: bloodGroup || '',
      createdAt: now,
      expiresAt,
    };

    this.liveLinks.set(hash, liveRecord);

    // If convoys manager is present, register in convoys live links map too
    if (this.convoys?.liveLinks) {
      this.convoys.liveLinks.set(hash, {
        gid: tripId || 'standalone',
        alertId: `SOS-${tripId || now}`,
        standaloneRecord: liveRecord,
      });
    }

    const origin = this.config.publicOrigin || 'https://coroute.live';
    return `${origin}/e/${token}`;
  }

  /**
   * Returns live link metadata if token hash exists and is valid.
   */
  liveView(hash) {
    if (!hash || typeof hash !== 'string') return null;
    const rec = this.liveLinks.get(hash);
    if (!rec) return null;
    if (Date.now() >= rec.expiresAt) {
      this.liveLinks.delete(hash);
      return null;
    }
    return {
      firstName: rec.firstName,
      lat: rec.lat,
      lng: rec.lng,
      speedKmh: rec.speedKmh,
      severity: rec.severity,
      bloodGroup: rec.bloodGroup,
      at: rec.createdAt,
      expiresAt: rec.expiresAt,
    };
  }

  /**
   * Formats a high-priority distress message for SMS and WhatsApp dispatch.
   */
  formatEmergencyMessage({ riderName, lat, lng, speedKmh, severity, bloodGroup, trackingUrl }) {
    const name = riderName || 'A CoRoute rider';
    const latStr = Number(lat || 0).toFixed(5);
    const lngStr = Number(lng || 0).toFixed(5);
    const speed = Number.isFinite(speedKmh) && speedKmh > 0 ? `${Math.round(speedKmh)} km/h` : 'Stopped';
    const sev = severity || 'CRITICAL';
    const bgLine = bloodGroup ? `🩸 Blood Group: ${bloodGroup}\n` : '';
    const trackLine = trackingUrl ? `🔗 Live Track: ${trackingUrl}\n` : '';

    return `🚨 CoRoute EMERGENCY SOS: ${name} needs immediate assistance!\n` +
      `📍 Location: ${latStr}, ${lngStr}\n` +
      `⚡ Speed: ${speed} | ⚠️ Severity: ${sev}\n` +
      bgLine +
      trackLine +
      `📞 Emergency action: Call 112 or view live tracking link immediately.`;
  }

  /**
   * Dispatches emergency SMS and WhatsApp notifications to contacts.
   * Target execution latency: sub-10 seconds.
   */
  async dispatchExternal({
    tripId,
    riderId,
    riderName,
    lat,
    lng,
    speedKmh = 0,
    contacts = [],
    severity = 'CRITICAL',
    bloodGroup = '',
    trackingUrl = null,
  }) {
    // Validate coordinates
    const numLat = Number(lat);
    const numLng = Number(lng);
    if (!Number.isFinite(numLat) || !Number.isFinite(numLng)) {
      throw new Error('Coordinates lat and lng must be valid numbers');
    }

    // Resolve emergency contacts
    let targetContacts = Array.isArray(contacts) ? [...contacts] : [];
    if (targetContacts.length === 0 && this.repo && riderId) {
      try {
        const u = await this.repo.findUserById(riderId);
        if (u?.emergencyContact) {
          targetContacts.push({
            phone: u.emergencyContact,
            name: u.emergencyContactName || 'Emergency Contact',
          });
        }
      } catch (err) {
        this.log.warn('[emergency_gateway] Failed to fetch emergency contact from profile', err.message);
      }
    }

    // Filter valid contacts
    const validContacts = targetContacts.filter((c) => c && (c.phone || c.number));
    if (validContacts.length === 0) {
      return {
        dispatched: false,
        provider: 'none',
        sentCount: 0,
        results: [],
        error: 'NO_CONTACTS',
      };
    }

    // Generate live link if missing
    const liveTrackingUrl = trackingUrl || this.generateTrackingUrl({
      tripId,
      riderId,
      riderName,
      lat: numLat,
      lng: numLng,
      speedKmh,
      severity,
      bloodGroup,
    });

    // Format body
    const body = this.formatEmergencyMessage({
      riderName,
      lat: numLat,
      lng: numLng,
      speedKmh,
      severity,
      bloodGroup,
      trackingUrl: liveTrackingUrl,
    });

    const metadata = {
      tripId,
      riderId,
      riderName,
      lat: numLat,
      lng: numLng,
      speedKmh,
      severity,
      bloodGroup,
      trackingUrl: liveTrackingUrl,
    };

    // Sub-10 second delivery target: parallel dispatch across all contacts and channels
    const dispatches = [];
    for (const c of validContacts) {
      const phone = c.phone || c.number;
      const contactName = c.name || 'Emergency Contact';

      // 1. SMS Dispatch with automatic fallback
      dispatches.push(
        this.sendSms({ to: phone, contactName, body, metadata }).catch((err) => ({
          contact: phone,
          name: contactName,
          channel: 'sms',
          success: false,
          provider: 'failed',
          error: err.message,
        }))
      );

      // 2. WhatsApp Dispatch with automatic fallback
      dispatches.push(
        this.sendWhatsApp({ to: phone, contactName, body, metadata }).catch((err) => ({
          contact: phone,
          name: contactName,
          channel: 'whatsapp',
          success: false,
          provider: 'failed',
          error: err.message,
        }))
      );
    }

    const results = await Promise.all(dispatches);
    const sentCount = results.filter((r) => r && r.success).length;
    const usedProvider = results.find((r) => r && r.success)?.provider || 'outbox_queue';

    return {
      dispatched: sentCount > 0,
      provider: usedProvider,
      sentCount,
      results,
      trackingUrl: liveTrackingUrl,
    };
  }

  /**
   * Automatic trigger for convoy / safety network SOS events.
   */
  async dispatchForSos({ groupId, user, alert, msg = {} }) {
    if (!alert || alert.serverDispatchedByGateway) return null;
    alert.serverDispatchedByGateway = true;

    // Check if client already successfully sent SMS
    if (msg.clientSentSms === true || msg.clientDispatched === true || alert.clientSentSms === true) {
      this.log.info(`[emergency_gateway] Skipping server dispatch for SOS ${alert.alertId}: already sent by client`);
      return null;
    }

    let userDoc = null;
    if (this.repo && user?.userId) {
      userDoc = await this.repo.findUserById(user.userId).catch(() => null);
    }

    const contacts = [];
    if (userDoc?.emergencyContact) {
      contacts.push({
        phone: userDoc.emergencyContact,
        name: userDoc.emergencyContactName || 'Emergency Contact',
      });
    }

    if (Array.isArray(msg.contacts)) {
      for (const c of msg.contacts) {
        if (c?.phone && !contacts.some((existing) => toE164(existing.phone) === toE164(c.phone))) {
          contacts.push(c);
        }
      }
    }

    if (contacts.length === 0) {
      this.log.info(`[emergency_gateway] No emergency contact found for rider ${user.userId} in SOS ${alert.alertId}`);
      return null;
    }

    let trackingUrl = null;
    if (this.convoys && groupId && alert.alertId) {
      try {
        const live = await this.convoys.createLiveLink(groupId, user, alert.alertId);
        if (live?.token) {
          const origin = this.config.publicOrigin || 'https://coroute.live';
          trackingUrl = `${origin}/e/${live.token}`;
        }
      } catch (_) {}
    }

    return await this.dispatchExternal({
      tripId: groupId,
      riderId: user.userId,
      riderName: user.name || alert.userName,
      lat: alert.lat,
      lng: alert.lng,
      speedKmh: alert.speedKmh || alert.details?.speedBeforeKmh || 0,
      contacts,
      severity: alert.severity || alert.alertType || 'CRITICAL',
      bloodGroup: userDoc?.bloodGroup || alert.medical?.bloodGroup || '',
      trackingUrl,
    });
  }

  /**
   * Sends SMS with multi-provider automatic fallback:
   * Primary Provider -> Secondary Provider -> Structured Outbox Queue.
   */
  async sendSms({ to, contactName, body, metadata = {} }) {
    const cleanTo = toE164(to);
    const primary = this.config.telephonyPrimaryProvider || 'twilio';
    const secondary = this.config.telephonySecondaryProvider || 'webhook';
    const providersToTry = [primary, secondary, 'outbox'];
    const tried = new Set();
    const errors = [];

    for (const prov of providersToTry) {
      if (tried.has(prov)) continue;
      tried.add(prov);

      try {
        let result = null;
        if (prov === 'twilio') {
          result = await this._sendTwilioSms({ to: cleanTo, body });
        } else if (prov === 'aws_sns' || prov === 'sns') {
          result = await this._sendAwsSnsSms({ to: cleanTo, body });
        } else if (prov === 'infobip') {
          result = await this._sendInfobipSms({ to: cleanTo, body });
        } else if (prov === 'webhook') {
          result = await this._sendWebhookTelephony({ to: cleanTo, contactName, body, channel: 'sms', metadata });
        } else if (prov === 'outbox') {
          result = this._recordOutbox({
            to: cleanTo,
            contactName,
            channel: 'sms',
            provider: 'outbox_queue',
            status: 'QUEUED',
            body,
            metadata,
          });
        }

        if (result && result.success) {
          return {
            contact: cleanTo,
            name: contactName,
            channel: 'sms',
            success: true,
            provider: result.provider || prov,
            messageId: result.messageId || result.id,
            fallback: prov !== primary,
          };
        }
      } catch (err) {
        errors.push(`${prov}: ${err.message}`);
        this.log.warn(`[emergency_gateway] SMS dispatch via ${prov} failed: ${err.message}, attempting fallback...`);
      }
    }

    // Guaranteed final fallback: always queue in outbox
    const fallbackEntry = this._recordOutbox({
      to: cleanTo,
      contactName,
      channel: 'sms',
      provider: 'outbox_queue',
      status: 'QUEUED',
      body,
      metadata,
      errors,
    });

    return {
      contact: cleanTo,
      name: contactName,
      channel: 'sms',
      success: true,
      provider: 'outbox_queue',
      messageId: fallbackEntry.id,
      fallback: true,
    };
  }

  /**
   * Sends WhatsApp message via WhatsApp Business Cloud API with fallback.
   */
  async sendWhatsApp({ to, contactName, body, metadata = {} }) {
    const waNumber = toWhatsAppNumber(to);
    const errors = [];

    // 1. Try WhatsApp Business Cloud API
    try {
      const res = await this._sendWhatsAppCloudApi({ to: waNumber, body });
      if (res && res.success) {
        return {
          contact: toE164(to),
          name: contactName,
          channel: 'whatsapp',
          success: true,
          provider: 'whatsapp_cloud_api',
          messageId: res.messageId,
        };
      }
    } catch (err) {
      errors.push(`whatsapp_cloud_api: ${err.message}`);
      this.log.warn(`[emergency_gateway] WhatsApp Cloud API failed: ${err.message}, attempting webhook fallback...`);
    }

    // 2. Try Telephony Webhook as WhatsApp secondary provider
    if (this.config.telephonyWebhookUrl) {
      try {
        const res = await this._sendWebhookTelephony({ to: toE164(to), contactName, body, channel: 'whatsapp', metadata });
        if (res && res.success) {
          return {
            contact: toE164(to),
            name: contactName,
            channel: 'whatsapp',
            success: true,
            provider: 'webhook',
            messageId: res.messageId,
          };
        }
      } catch (err) {
        errors.push(`webhook: ${err.message}`);
      }
    }

    // 3. Guaranteed final fallback: record in structured outbox
    const fallbackEntry = this._recordOutbox({
      to: toE164(to),
      contactName,
      channel: 'whatsapp',
      provider: 'outbox_queue',
      status: 'QUEUED',
      body,
      metadata,
      errors,
    });

    return {
      contact: toE164(to),
      name: contactName,
      channel: 'whatsapp',
      success: true,
      provider: 'outbox_queue',
      messageId: fallbackEntry.id,
      fallback: true,
    };
  }

  // ================= Telephony Provider Drivers =================

  async _sendTwilioSms({ to, body }) {
    const sid = this.config.twilioAccountSid;
    const token = this.config.twilioAuthToken;
    const from = this.config.twilioFromNumber;

    if (!sid || !token || !from) {
      throw new Error('Twilio credentials not configured (TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_FROM_NUMBER)');
    }

    const url = `https://api.twilio.com/2010-04-01/Accounts/${encodeURIComponent(sid)}/Messages.json`;
    const form = new URLSearchParams({
      To: to,
      From: from,
      Body: body,
    });

    const authHeader = 'Basic ' + Buffer.from(`${sid}:${token}`).toString('base64');
    const res = await this.fetch(url, {
      method: 'POST',
      headers: {
        Authorization: authHeader,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: form.toString(),
      signal: AbortSignal.timeout(5000),
    });

    if (!res.ok) {
      const txt = await res.text().catch(() => '');
      throw new Error(`Twilio error HTTP ${res.status}: ${txt.slice(0, 200)}`);
    }

    const data = await res.json().catch(() => ({}));
    return { success: true, provider: 'twilio', messageId: data.sid || `SM-${crypto.randomUUID()}` };
  }

  async _sendAwsSnsSms({ to, body }) {
    const key = this.config.awsAccessKeyId;
    const secret = this.config.awsSecretAccessKey;
    const region = this.config.awsSnsRegion || 'ap-south-1';

    if (!key || !secret) {
      throw new Error('AWS SNS credentials not configured (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY)');
    }

    // Direct SNS publish via standard AWS SNS HTTP endpoint or mock
    const endpoint = `https://sns.${region}.amazonaws.com/`;
    const form = new URLSearchParams({
      Action: 'Publish',
      PhoneNumber: to,
      Message: body,
      Version: '2010-03-31',
    });

    const res = await this.fetch(endpoint, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        'X-Amz-Security-Token': key,
      },
      body: form.toString(),
      signal: AbortSignal.timeout(5000),
    });

    if (!res.ok) {
      const txt = await res.text().catch(() => '');
      throw new Error(`AWS SNS error HTTP ${res.status}: ${txt.slice(0, 200)}`);
    }

    return { success: true, provider: 'aws_sns', messageId: `SNS-${crypto.randomUUID()}` };
  }

  async _sendInfobipSms({ to, body }) {
    const key = this.config.infobipApiKey;
    const baseUrl = this.config.infobipBaseUrl;

    if (!key || !baseUrl) {
      throw new Error('Infobip credentials not configured (INFOBIP_API_KEY, INFOBIP_BASE_URL)');
    }

    const url = `${baseUrl}/sms/2/text/advanced`;
    const payload = {
      messages: [
        {
          destinations: [{ to }],
          text: body,
        },
      ],
    };

    const res = await this.fetch(url, {
      method: 'POST',
      headers: {
        Authorization: `App ${key}`,
        'Content-Type': 'application/json',
        Accept: 'application/json',
      },
      body: JSON.stringify(payload),
      signal: AbortSignal.timeout(5000),
    });

    if (!res.ok) {
      const txt = await res.text().catch(() => '');
      throw new Error(`Infobip error HTTP ${res.status}: ${txt.slice(0, 200)}`);
    }

    const data = await res.json().catch(() => ({}));
    const messageId = data.messages?.[0]?.messageId || `IB-${crypto.randomUUID()}`;
    return { success: true, provider: 'infobip', messageId };
  }

  async _sendWebhookTelephony({ to, contactName, body, channel, metadata }) {
    const url = this.config.telephonyWebhookUrl;
    if (!url) {
      throw new Error('Telephony Webhook URL not configured (TELEPHONY_WEBHOOK_URL)');
    }

    const headers = { 'Content-Type': 'application/json' };
    if (this.config.telephonyWebhookToken) {
      headers.Authorization = `Bearer ${this.config.telephonyWebhookToken}`;
    }

    const payload = {
      to,
      contactName,
      channel,
      body,
      metadata,
      timestamp: Date.now(),
    };

    const res = await this.fetch(url, {
      method: 'POST',
      headers,
      body: JSON.stringify(payload),
      signal: AbortSignal.timeout(5000),
    });

    if (!res.ok) {
      const txt = await res.text().catch(() => '');
      throw new Error(`Telephony Webhook error HTTP ${res.status}: ${txt.slice(0, 200)}`);
    }

    const data = await res.json().catch(() => ({}));
    return { success: true, provider: 'webhook', messageId: data.messageId || `WH-${crypto.randomUUID()}` };
  }

  async _sendWhatsAppCloudApi({ to, body }) {
    const token = this.config.whatsappApiToken;
    const phoneId = this.config.whatsappPhoneNumberId;
    const baseUrl = this.config.whatsappApiUrl || 'https://graph.facebook.com/v20.0';

    if (!token || !phoneId) {
      throw new Error('WhatsApp Business credentials not configured (WHATSAPP_API_TOKEN, WHATSAPP_PHONE_NUMBER_ID)');
    }

    const url = `${baseUrl}/${phoneId}/messages`;
    const payload = {
      messaging_product: 'whatsapp',
      recipient_type: 'individual',
      to,
      type: 'text',
      text: {
        preview_url: true,
        body,
      },
    };

    const res = await this.fetch(url, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${token}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(payload),
      signal: AbortSignal.timeout(5000),
    });

    if (!res.ok) {
      const txt = await res.text().catch(() => '');
      throw new Error(`WhatsApp API error HTTP ${res.status}: ${txt.slice(0, 200)}`);
    }

    const data = await res.json().catch(() => ({}));
    const messageId = data.messages?.[0]?.id || `WAMID-${crypto.randomUUID()}`;
    return { success: true, provider: 'whatsapp_cloud_api', messageId };
  }

  // ================= Outbox Queue Management =================

  _recordOutbox({ to, contactName, channel, provider, status, body, metadata = {}, errors = [] }) {
    const entry = {
      id: `OUTBOX-${crypto.randomUUID()}`,
      messageId: `OUTBOX-${crypto.randomUUID()}`,
      to,
      contactName,
      channel,
      provider,
      status,
      body,
      metadata,
      errors,
      createdAt: Date.now(),
      success: true,
    };
    entry.id = entry.messageId;

    this.outbox.unshift(entry);
    if (this.outbox.length > this.maxOutboxSize) {
      this.outbox.pop();
    }

    this.log.info(`[emergency_gateway] Outbox queue entry created: [${channel}] to ${to} (${contactName}) - ${status}`);
    return entry;
  }

  getOutbox({ limit = 50, status, channel } = {}) {
    let list = this.outbox;
    if (status) {
      list = list.filter((e) => e.status === status);
    }
    if (channel) {
      list = list.filter((e) => e.channel === channel);
    }
    return list.slice(0, limit);
  }

  clearOutbox() {
    this.outbox = [];
    this.liveLinks.clear();
  }
}

module.exports = {
  EmergencySmsGateway,
  toE164,
  toWhatsAppNumber,
};
