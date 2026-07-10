import 'dart:convert';

import 'phone_normalizer.dart';

class WebWhatsAppScanResult {
  const WebWhatsAppScanResult({
    required this.ready,
    required this.loginRequired,
    required this.groups,
    required this.error,
    required this.source,
  });

  final bool ready;
  final bool loginRequired;
  final List<WebWhatsAppGroupCandidate> groups;
  final String error;
  final String source;

  factory WebWhatsAppScanResult.fromRawJavaScriptResult(Object? raw) {
    final text = _decodeJavaScriptResult(raw);
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) {
        return WebWhatsAppScanResult.fromJson(decoded);
      }
      if (decoded is Map) {
        return WebWhatsAppScanResult.fromJson(
          decoded.map((key, value) => MapEntry('$key', value)),
        );
      }
      return const WebWhatsAppScanResult(
        ready: false,
        loginRequired: false,
        groups: [],
        error: 'WhatsApp Web scan returned no readable data.',
        source: 'whatsapp_web',
      );
    } catch (error) {
      return WebWhatsAppScanResult(
        ready: false,
        loginRequired: false,
        groups: const [],
        error: 'WhatsApp Web scan result could not be parsed: $error',
        source: 'whatsapp_web',
      );
    }
  }

  factory WebWhatsAppScanResult.fromJson(Map<String, dynamic> json) {
    final rawGroups = json['groups'];
    return WebWhatsAppScanResult(
      ready: json['ready'] == true,
      loginRequired: json['loginRequired'] == true,
      groups: rawGroups is List
          ? rawGroups
                .whereType<Map>()
                .map(
                  (group) => WebWhatsAppGroupCandidate.fromJson(
                    group.map((key, value) => MapEntry('$key', value)),
                  ),
                )
                .toList()
          : const [],
      error: '${json['error'] ?? ''}',
      source: '${json['source'] ?? 'whatsapp_web'}',
    );
  }

  static String _decodeJavaScriptResult(Object? raw) {
    if (raw == null) {
      return '{}';
    }
    if (raw is String) {
      final trimmed = raw.trim();
      if (trimmed.startsWith('"') && trimmed.endsWith('"')) {
        return jsonDecode(trimmed) as String;
      }
      return trimmed;
    }
    return '$raw';
  }
}

class WebWhatsAppGroupCandidate {
  const WebWhatsAppGroupCandidate({
    required this.whatsappId,
    required this.name,
    required this.estimatedMemberCount,
    required this.members,
  });

  final String whatsappId;
  final String name;
  final int estimatedMemberCount;
  final List<WebWhatsAppMemberCandidate> members;

  factory WebWhatsAppGroupCandidate.fromJson(Map<String, Object?> json) {
    final rawMembers = json['members'];
    final parsedMembers = rawMembers is List
        ? rawMembers
              .whereType<Map>()
              .map(
                (member) => WebWhatsAppMemberCandidate.fromJson(
                  member.map((key, value) => MapEntry('$key', value)),
                ),
              )
              .toList()
        : const <WebWhatsAppMemberCandidate>[];
    return WebWhatsAppGroupCandidate(
      whatsappId: '${json['id'] ?? json['whatsapp_id'] ?? ''}',
      name: '${json['name'] ?? ''}'.trim(),
      estimatedMemberCount:
          int.tryParse(
            '${json['estimatedMemberCount'] ?? json['count'] ?? 0}',
          ) ??
          parsedMembers.length,
      members: parsedMembers,
    );
  }
}

class WebWhatsAppMemberCandidate {
  const WebWhatsAppMemberCandidate({
    required this.whatsappId,
    required this.displayName,
    required this.phone,
    required this.normalizedPhone,
    required this.isAdmin,
    required this.phoneVisibility,
  });

  final String whatsappId;
  final String displayName;
  final String phone;
  final String normalizedPhone;
  final bool isAdmin;
  final String phoneVisibility;

  factory WebWhatsAppMemberCandidate.fromJson(Map<String, Object?> json) {
    final id = '${json['id'] ?? json['whatsapp_id'] ?? ''}';
    final phone = '${json['phone'] ?? ''}'.trim();
    final normalizedPhone = PhoneNormalizer.normalize(phone);
    return WebWhatsAppMemberCandidate(
      whatsappId: id,
      displayName: '${json['name'] ?? json['displayName'] ?? phone}'.trim(),
      phone: phone,
      normalizedPhone: normalizedPhone,
      isAdmin: _boolFromJson(json['isAdmin'] ?? json['is_admin']),
      phoneVisibility: normalizedPhone.isEmpty ? 'notVisible' : 'visible',
    );
  }

  static bool _boolFromJson(Object? value) {
    if (value is bool) {
      return value;
    }
    if (value is num) {
      return value != 0;
    }
    final text = '$value'.toLowerCase();
    return text == 'true' || text == '1' || text == 'admin';
  }
}

class WebGroupSelection {
  const WebGroupSelection._();

  static Set<String> selectAll(Iterable<WebWhatsAppGroupCandidate> groups) {
    return groups
        .map((group) => group.whatsappId)
        .where((id) => id.isNotEmpty)
        .toSet();
  }

  static List<WebWhatsAppGroupCandidate> selectedGroups(
    Iterable<WebWhatsAppGroupCandidate> groups,
    Set<String> selectedIds,
  ) {
    return groups
        .where((group) => selectedIds.contains(group.whatsappId))
        .toList();
  }
}

class WebWhatsAppExtractor {
  const WebWhatsAppExtractor._();

  static const String desktopUserAgent =
      'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  static const String quickScanScript = r'''
(function waGroupExtractorQuickScan() {
  const result = {
    ready: false,
    loginRequired: false,
    groups: [],
    error: '',
    source: 'whatsapp_web_dom'
  };

  const textOf = (value) => (value == null ? '' : String(value)).trim();
  const clean = (value) => textOf(value).replace(/\s+/g, ' ');
  const bodyText = () => document.body ? document.body.innerText || '' : '';
  const hasLoginUi = () => /link a device|linked devices|use whatsapp on your computer|scan the qr|scan to log in|log in with phone number|stay logged in/i.test(bodyText());
  const hasAppUi = () => {
    const body = bodyText();
    return !hasLoginUi() && (
      /search|start a new chat|new chat|archived|unread|groups|chats|communities|status|channels|whatsapp business/i.test(body) ||
      Boolean(document.querySelector('#app, #pane-side, [role="grid"], [role="gridcell"], [contenteditable="true"], [data-testid="cell-frame-container"]'))
    );
  };
  const phoneRegex = /\+?\d[\d\s().-]{5,}\d/;
  const adminRegex = /\b(admin|group admin)\b/i;
  const noiseRegex = /^(all|unread|groups|\+|chats|status|channels|communities|tools|new chat|search|search or start a new chat|reach more customers faster|get started|whatsapp|whatsapp business|whatsapp group invite|archived|yesterday|today|typing|online)$/i;
  const dateRegex = /^(\d{1,2}:\d{2}|yesterday|today|\d{1,2}\/\d{1,2}\/\d{2,4}|\d{1,2}-\d{1,2}-\d{2,4}|monday|tuesday|wednesday|thursday|friday|saturday|sunday)$/i;
  const groups = new Map();

  const safeGroupId = (name) => `visible-${name.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 60) || Date.now()}@g.us`;
  const isNoise = (value) => {
    const text = clean(value);
    if (text.length < 2 || text.length > 90) return true;
    if (noiseRegex.test(text) || dateRegex.test(text)) return true;
    if (/^(messages and calls are end-to-end encrypted|you created the group|it was added to the community|type a message|voice message|attach|emojis|gif|stickers)/i.test(text)) return true;
    if (/\bunread messages?\b|\bmessage unread\b|whatsapp group invite|https?:\/\/|instagram\.com/i.test(text)) return true;
    if (/^\d+$/.test(text)) return true;
    return false;
  };
  const rememberGroup = (name, members = [], estimatedMemberCount = 0) => {
    const cleanName = clean(name);
    if (isNoise(cleanName) || phoneRegex.test(cleanName)) return;
    const id = safeGroupId(cleanName);
    const existing = groups.get(id) || { id, name: cleanName, estimatedMemberCount: 0, members: [] };
    const seen = new Set(existing.members.map((member) => member.id || member.phone || member.name));
    for (const member of members) {
      const key = member.id || member.phone || member.name;
      if (key && !seen.has(key)) {
        existing.members.push(member);
        seen.add(key);
      }
    }
    existing.estimatedMemberCount = Math.max(existing.estimatedMemberCount || 0, estimatedMemberCount || existing.members.length);
    groups.set(id, existing);
  };
  const memberFromText = (text) => {
    const phone = (text.match(phoneRegex) || [''])[0];
    if (!phone) return null;
    const digits = phone.replace(/\D/g, '');
    const name = clean(text.replace(phone, '').replace(adminRegex, ''));
    return { id: `${digits}@c.us`, name: name || phone, phone, isAdmin: adminRegex.test(text) };
  };

  result.loginRequired = hasLoginUi() && !hasAppUi();
  result.ready = hasAppUi() && !result.loginRequired;
  if (result.loginRequired || !result.ready) {
    result.error = result.loginRequired ? 'WhatsApp Web login is required.' : 'WhatsApp Web is not ready.';
    return JSON.stringify(result);
  }

  const rowSelectors = [
    '[data-testid="cell-frame-container"]',
    '[role="gridcell"]',
    '[aria-label*="chat" i]',
    '[aria-label*="group" i]'
  ];
  const rows = Array.from(document.querySelectorAll(rowSelectors.join(','))).slice(0, 120);
  for (const row of rows) {
    const lines = (row.innerText || row.getAttribute('aria-label') || row.getAttribute('title') || '')
      .split(/\n+/)
      .map(clean)
      .filter((line) => !isNoise(line));
    const name = lines.find((line) => !phoneRegex.test(line));
    if (name) rememberGroup(name);
  }

  const fullLines = bodyText()
    .split(/\n+/)
    .map(clean)
    .filter((line) => line.length > 1 && line.length < 120);
  const phoneMembers = fullLines
    .map(memberFromText)
    .filter(Boolean)
    .slice(0, 300);
  const hasGroupInfoSignal = fullLines.some((line) => /add members|invite to group via link|participants|group info/i.test(line));
  if (hasGroupInfoSignal) {
    const groupName = fullLines.find((line) =>
      !isNoise(line) &&
      !phoneRegex.test(line) &&
      !/add members|invite to group via link|participants|group info|message|search|click to learn more/i.test(line)
    );
    if (groupName) rememberGroup(groupName, phoneMembers, phoneMembers.length);
  }

  if (groups.size === 0) {
    const groupTabIndex = fullLines.findIndex((line) => /^groups$/i.test(line));
    const candidateLines = groupTabIndex >= 0 ? fullLines.slice(groupTabIndex + 1, groupTabIndex + 80) : fullLines.slice(0, 120);
    for (const line of candidateLines) {
      if (!isNoise(line) && !phoneRegex.test(line)) {
        rememberGroup(line);
      }
      if (groups.size >= 30) break;
    }
  }

  result.groups = Array.from(groups.values()).sort((a, b) => a.name.localeCompare(b.name));
  if (result.groups.length === 0) {
    result.error = 'WhatsApp Web is linked, but no visible groups were readable. Open the Groups filter or a group info screen and scan again.';
  }
  return JSON.stringify(result);
})()
''';

  static const String scanScript = r'''
(function waGroupExtractorBootstrap() {
  const finish = (payload) => {
    const text = JSON.stringify(payload);
    try {
      if (window.WaGroupExtractorBridge && window.WaGroupExtractorBridge.postMessage) {
        window.WaGroupExtractorBridge.postMessage(text);
      }
    } catch (_) {}
    return text;
  };

  (async function waGroupExtractor() {
  const result = {
    ready: false,
    loginRequired: false,
    groups: [],
    error: '',
    source: 'whatsapp_web'
  };
  let stopIndexedDbScan = false;
  let inspectedObjects = 0;

  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  const textOf = (value) => (value == null ? '' : String(value)).trim();
  const idToString = (value) => {
    if (!value) return '';
    if (typeof value === 'string') return value;
    if (value._serialized) return String(value._serialized);
    if (value.serialized) return String(value.serialized);
    if (value.__x_id) return idToString(value.__x_id);
    if (value.id) return idToString(value.id);
    if (value.wid) return idToString(value.wid);
    if (value.jid) return idToString(value.jid);
    if (value.user && value.server) return `${value.user}@${value.server}`;
    return '';
  };
  const isGroupId = (value) => /@g\.us$/.test(idToString(value));
  const isContactId = (value) => /@c\.us$/.test(idToString(value));
  const phoneFromId = (value) => {
    const id = idToString(value);
    const match = id.match(/^(\d{6,})@c\.us$/);
    return match ? match[1] : '';
  };
  const cleanName = (value) => textOf(value).replace(/\s+/g, ' ');
  const candidateName = (obj) => cleanName(
    obj?.name || obj?.pushname || obj?.verifiedName || obj?.formattedName ||
    obj?.displayName || obj?.shortName || obj?.notifyName || obj?.subject ||
    obj?.title || obj?.formattedTitle || obj?.__x_name ||
    obj?.__x_formattedTitle || obj?.__x_subject || ''
  );
  const asArray = (value) => {
    if (!value) return [];
    if (Array.isArray(value)) return value;
    if (value instanceof Map) return Array.from(value.values());
    if (value instanceof Set) return Array.from(value.values());
    if (value._models && Array.isArray(value._models)) return value._models;
    if (value.models && Array.isArray(value.models)) return value.models;
    if (value._index) return Object.values(value._index);
    if (typeof value === 'object') return Object.values(value);
    return [];
  };
  const hasLoginUi = () => {
    const body = document.body ? document.body.innerText || '' : '';
    return /link a device|linked devices|use whatsapp on your computer|scan the qr|scan to log in|log in with phone number|stay logged in/i.test(body);
  };
  const hasAppUi = () => {
    const body = document.body ? document.body.innerText || '' : '';
    const login = hasLoginUi();
    const selectors = [
      '#app',
      '#pane-side',
      '[data-testid="chat-list"]',
      '[data-testid="cell-frame-container"]',
      '[aria-label*="Chat list"]',
      '[aria-label*="chat list"]',
      '[aria-label*="Search input"]',
      '[contenteditable="true"]',
      '[role="grid"]',
      '[role="gridcell"]',
      '[role="textbox"]'
    ];
    return !login && (/search|start a new chat|start new chat|new chat|archived|unread|groups|chats|communities|status|channels|whatsapp business/i.test(body) ||
      selectors.some((selector) => Boolean(document.querySelector(selector)));
  };

  await sleep(300);
  result.loginRequired = hasLoginUi() && !hasAppUi();
  result.ready = hasAppUi() && !result.loginRequired;

  const contacts = new Map();
  const groups = new Map();

  const rememberContact = (obj) => {
    const id = idToString(obj?.id || obj?.wid || obj?.jid || obj?.participant || obj?.contact);
    if (!id && !obj) return;
    const phone = phoneFromId(id || obj);
    const name = candidateName(obj) || phone || id;
    const key = id || phone || name;
    if (!key) return;
    const existing = contacts.get(key) || {};
    contacts.set(key, {
      id: existing.id || id || key,
      phone: existing.phone || phone,
      name: existing.name || name
    });
  };

  const memberFrom = (raw) => {
    const id = idToString(raw?.id || raw?.wid || raw?.jid || raw?.participant || raw?.contact || raw);
    const contact = contacts.get(id) || {};
    const phone = phoneFromId(id) || contact.phone || '';
    const name = candidateName(raw) || contact.name || phone || id;
    const isAdmin = Boolean(raw?.isAdmin || raw?.isSuperAdmin || raw?.admin || raw?.is_admin);
    return { id, name, phone, isAdmin };
  };

  const rememberGroup = (obj) => {
    const id = idToString(obj?.id || obj?.jid || obj?.wid || obj);
    if (!isGroupId(id)) return;
    const name = candidateName(obj) || id;
    const participantFields = [
      obj?.participants,
      obj?.__x_participants,
      obj?.groupMetadata?.participants,
      obj?.groupMetadata?.__x_participants,
      obj?.__x_groupMetadata?.participants,
      obj?.__x_groupMetadata?.__x_participants,
      obj?.metadata?.participants,
      obj?.participantCollection,
      obj?.participantsCollection
    ];
    const members = [];
    const seen = new Set();
    for (const field of participantFields) {
      for (const rawMember of asArray(field)) {
        const member = memberFrom(rawMember);
        const key = member.id || member.phone || member.name;
        if (!key || seen.has(key)) continue;
        seen.add(key);
        members.push(member);
      }
    }
    const existing = groups.get(id) || { id, name, members: [] };
    const mergedSeen = new Set(existing.members.map((member) => member.id || member.phone || member.name));
    for (const member of members) {
      const key = member.id || member.phone || member.name;
      if (!mergedSeen.has(key)) {
        existing.members.push(member);
        mergedSeen.add(key);
      }
    }
    existing.name = existing.name || name;
    existing.estimatedMemberCount = Math.max(
      existing.estimatedMemberCount || 0,
      Number(obj?.participantsCount || obj?.participantCount || obj?.size || members.length || 0)
    );
    groups.set(id, existing);
  };

  const inspectObject = (obj, depth = 0) => {
    if (!obj || depth > 4 || typeof obj !== 'object' || inspectedObjects > 30000) return;
    inspectedObjects += 1;
    try {
      if (isContactId(obj?.id || obj?.wid || obj?.jid)) rememberContact(obj);
      if (isGroupId(obj?.id || obj?.jid || obj?.wid || obj)) rememberGroup(obj);
      if (obj.chat && isGroupId(obj.chat?.id || obj.chat?.jid)) rememberGroup(obj.chat);
      if (obj.contact) rememberContact(obj.contact);
      const keys = [
        '__x_contact',
        '__x_groupMetadata',
        '__x_participants',
        '_value',
        'value',
        'groupMetadata',
        'metadata',
        'chat',
        'Chat',
        'contact',
        'Contact',
        'GroupMetadata',
        'GroupMetadataStore',
        'Participant',
        'Participants',
        'Store',
        'participants',
        'participantCollection',
        'participantsCollection',
        '_models',
        'models',
        '_index',
        'map',
        'collection'
      ];
      for (const key of keys) {
        if (obj[key]) inspectObject(obj[key], depth + 1);
      }
      const dynamicKeys = Object.keys(obj).slice(0, 80);
      for (const key of dynamicKeys) {
        if (/chat|contact|group|participant|metadata|model|store|collection/i.test(key)) {
          inspectObject(obj[key], depth + 1);
        }
      }
    } catch (_) {}
  };

  const readWebpackStores = async () => {
    const chunkNames = [
      'webpackChunkwhatsapp_web_client',
      'webpackChunkwhatsapp_web_client_main',
      'webpackChunkwhatsapp_web',
      'webpackChunkbuild'
    ];
    const modules = [];
    for (const name of chunkNames) {
      const chunk = window[name];
      if (!chunk || !Array.isArray(chunk) || typeof chunk.push !== 'function') continue;
      try {
        chunk.push([[`wa_group_extractor_${Date.now()}_${Math.random()}`], {}, (require) => {
          if (!require || !require.c) return;
          for (const key of Object.keys(require.c)) {
            const module = require.c[key];
            if (module && module.exports) modules.push(module.exports);
          }
        }]);
      } catch (_) {}
    }

    const globals = [
      window.Store,
      window.WPP,
      window.Debug,
      window.require,
      window.mR
    ].filter(Boolean);
    for (const global of globals) modules.push(global);

    const seen = new Set();
    for (const moduleExports of modules.slice(0, 1800)) {
      if (!moduleExports || inspectedObjects > 30000) break;
      if ((typeof moduleExports === 'object' || typeof moduleExports === 'function') && seen.has(moduleExports)) continue;
      if (typeof moduleExports === 'object' || typeof moduleExports === 'function') seen.add(moduleExports);
      inspectObject(moduleExports, 0);
      if (moduleExports.default) inspectObject(moduleExports.default, 0);
      if (typeof moduleExports === 'object') {
        const values = Object.values(moduleExports).slice(0, 40);
        for (const value of values) {
          if (!value || typeof value !== 'object') continue;
          const keys = Object.keys(value).join(' ');
          if (/_models|models|chat|contact|group|participant|metadata|store|collection/i.test(keys)) {
            inspectObject(value, 0);
          }
        }
      }
    }
  };

  const readIndexedDb = async () => {
    if (!window.indexedDB || !indexedDB.databases) return;
    const dbs = await indexedDB.databases();
    for (const info of dbs) {
      if (!info.name || !/wa|wweb|model|storage|app/i.test(info.name)) continue;
      await new Promise((resolve) => {
        const request = indexedDB.open(info.name);
        request.onerror = () => resolve();
        request.onsuccess = () => {
          const db = request.result;
          let stores = Array.from(db.objectStoreNames || [])
            .filter((storeName) => /chat|contact|group|participant|model|storage|wawc|wa/i.test(storeName));
          stores = stores.slice(0, 16);
          if (stores.length === 0) {
            db.close();
            resolve();
            return;
          }
          let remaining = stores.length;
          const done = () => {
            remaining -= 1;
            if (remaining <= 0) {
              db.close();
              resolve();
            }
          };
          for (const storeName of stores) {
            try {
              const tx = db.transaction(storeName, 'readonly');
              const store = tx.objectStore(storeName);
              let count = 0;
              const cursor = store.openCursor();
              cursor.onerror = done;
              cursor.onsuccess = (event) => {
                const current = event.target.result;
                if (stopIndexedDbScan || !current || count > 900) {
                  done();
                  return;
                }
                count += 1;
                inspectObject(current.value, 0);
                current.continue();
              };
            } catch (_) {
              done();
            }
          }
        };
      });
    }
  };

  const readDomFallback = () => {
    const titleNodes = Array.from(document.querySelectorAll('[title], [aria-label], span, div'))
      .slice(0, 2000);
    const texts = titleNodes
      .map((node) => cleanName(node.getAttribute('title') || node.getAttribute('aria-label') || node.innerText || ''))
      .filter((text) => text.length > 1 && text.length < 120);
    const uniqueTexts = Array.from(new Set(texts));
    const groupSignals = uniqueTexts.filter((text) => /\bparticipants?\b|\bmembers?\b/i.test(text));
    const phoneTexts = uniqueTexts.filter((text) => /\+?\d[\d\s().-]{5,}\d/.test(text));
    if (phoneTexts.length === 0 && groupSignals.length === 0) return;
    const groupName = uniqueTexts.find((text) =>
      !/\+?\d[\d\s().-]{5,}\d/.test(text) &&
      !/\bparticipants?\b|\bmembers?\b|search|message|call|video|admin/i.test(text)
    ) || 'Visible WhatsApp group';
    const domGroup = {
      id: `visible-dom-${Date.now()}@g.us`,
      name: groupName,
      estimatedMemberCount: phoneTexts.length,
      members: phoneTexts.map((text) => {
        const phone = (text.match(/\+?\d[\d\s().-]{5,}\d/) || [''])[0];
        return { id: phone ? `${phone.replace(/\D/g, '')}@c.us` : text, name: text.replace(phone, '').trim() || phone, phone, isAdmin: /admin/i.test(text) };
      })
    };
    groups.set(domGroup.id, domGroup);
  };

  try {
    let localDataTimedOut = false;
    await readWebpackStores();
    await Promise.race([
      readIndexedDb(),
      sleep(6500).then(() => {
        localDataTimedOut = true;
        stopIndexedDbScan = true;
      })
    ]);
    readDomFallback();
    result.groups = Array.from(groups.values())
      .map((group) => ({
        id: group.id,
        name: group.name || group.id,
        estimatedMemberCount: group.estimatedMemberCount || group.members.length,
        members: group.members
      }))
      .sort((a, b) => a.name.localeCompare(b.name));
    if (localDataTimedOut && result.groups.length === 0) {
      result.error = 'WhatsApp Web is linked, but the local group data scan timed out. Use Phone capture, or open a group info screen in Web and scan again.';
    }
    if (result.groups.length === 0 && hasLoginUi()) {
      result.loginRequired = true;
      result.ready = false;
      result.error = result.error || 'WhatsApp Web login is required.';
    }
  } catch (error) {
    result.error = String(error && error.message ? error.message : error);
  }

  finish(result);
  })().catch((error) => finish({
    ready: false,
    loginRequired: false,
    groups: [],
    error: String(error && error.message ? error.message : error),
    source: 'whatsapp_web'
  }));

  return 'started';
})()
''';
}
