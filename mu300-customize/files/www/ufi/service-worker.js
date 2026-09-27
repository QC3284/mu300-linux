// 自我注销的 Service Worker
//   原因:UFI 前端自带的 SW 把页面缓存住,导致后端改动(need_token=false)不生效
//   替换版在激活时注销自己,并让所有页面重新加载
self.addEventListener('install', function() { self.skipWaiting(); });
self.addEventListener('activate', function(e) {
  e.waitUntil((async function() {
    try { await self.registration.unregister(); } catch (err) { }
    var cs = await self.clients.matchAll({ type: 'window' });
    for (var i = 0; i < cs.length; i++) { try { cs[i].navigate(cs[i].url); } catch (err) { } }
  })());
});
self.addEventListener('fetch', function(e) {
  e.respondWith(fetch(e.request).catch(function() { return new Response('', { status: 504 }); }));
});
