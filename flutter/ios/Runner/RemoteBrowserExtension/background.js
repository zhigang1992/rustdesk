(async () => {
  try {
    const rules = [];
    for (const scheme of ['http', 'https', 'ws', 'wss']) {
      for (const [host, alias] of Object.entries({
        localhost: 'localhost.rustdesk.localhost',
        '127.0.0.1': 'ipv4.rustdesk.localhost', '[::1]': 'ipv6.rustdesk.localhost'
      })) {
        rules.push({id: rules.length + 1, priority: 1,
          action: {type: 'redirect', redirect: {transform: {host: alias}}},
          condition: {urlFilter: `|${scheme}://${host}^`, resourceTypes: [
            'main_frame', 'sub_frame', 'xmlhttprequest', 'script', 'image',
            'stylesheet', 'font', 'media', 'websocket', 'other', 'ping'
          ]}});
      }
    }
    await browser.declarativeNetRequest.updateSessionRules({
      removeRuleIds: rules.map(rule => rule.id), addRules: rules
    });
    await browser.runtime.sendNativeMessage({ready: true});
  } catch (error) {
    await browser.runtime.sendNativeMessage({error: String(error)});
  }
})();
