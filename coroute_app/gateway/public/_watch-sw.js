/* No offline cache: private trip data is always fetched with current authorization. */
self.addEventListener('push', (event) => {
  let data;
  try { data = event.data.json(); } catch { return; }
  if (!data || typeof data !== 'object') return;
  const url = typeof data.url === 'string' && /^\/watch#ticket=[A-Za-z0-9_-]{32}$/.test(data.url) ? data.url : '/watch';
  event.waitUntil(self.registration.showNotification('CoRoute trip update', {
    body: 'Open Ride Guardian for the latest shared update.', tag: String(data.tag || 'guardian'),
    data: { url }, icon: '/icon-512.png', renotify: false,
  }));
});
self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const candidate = event.notification.data?.url;
  const url = typeof candidate === 'string' && /^\/watch#ticket=[A-Za-z0-9_-]{32}$/.test(candidate) ? candidate : '/watch';
  event.waitUntil(self.clients.openWindow(url));
});
