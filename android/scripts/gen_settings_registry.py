#!/usr/bin/env python3
"""Writes SettingsRegistryData.kt from the Settings pages: every ToggleRow, ChoiceRow, ActionRow and SettingRow with its title and description, the page it is on and whether Essential shows it.
Run from the android folder:  python3 scripts/gen_settings_registry.py     (SettingsRegistryCoverageTest fails when the pages and this list drift apart)."""
import re, glob, os
D = 'app/src/main/kotlin/app/streamsetu/tv/ui/screens/settings'
PAGES = {'PlaybackSettings':'PLAYBACK','AppDnsGroup':'PLAYBACK','VideoSettings':'VIDEO','AudioSettings':'AUDIO','SubtitleSettings':'SUBTITLES','LiveSettings':'LIVE','RemindersSettings':'LIVE','GuideAlertsSettings':'LIVE','ScheduledRecordingsSettings':'LIVE','GuideSettingsContent':'LIVE',
 'ChannelManagerSettings':'CHANNELS','DeviceSettings':'DEVICE','WeeklyDigestSettings':'STATISTICS','StatisticsSettings':'STATISTICS','LibrarySettings':'LIBRARIES','FolderResets':'LIBRARIES','SearchSettings':'SEARCH','FavouriteSettings':'FAVOURITES','AppearanceSettings':'APPEARANCE',
 'PrivacySettings':'PRIVACY','PrivacyReportSettings':'PRIVACY','ViewingLimitSettings':'PRIVACY','PodcastSettings':'PODCASTS','IntegrationsSettings':'INTEGRATIONS','TraktSettings':'INTEGRATIONS','DebridSettings':'INTEGRATIONS','AiSettings':'INTEGRATIONS','AskAiSettings':'INTEGRATIONS',
 'ProfileSettings':'PROFILES','SyncSettings':'SYNC','AddonsSettings':'ADDONS','StorageSettings':'STORAGE','DiagnosticsSettings':'DIAGNOSTICS','PlaybackCapabilitiesGroup':'DIAGNOSTICS','AboutSettings':'ABOUT','UpdateSettings':'ABOUT'}
ADVANCED_CATEGORIES = {'CHANNELS','DEVICE','STATISTICS','PODCASTS','INTEGRATIONS','SYNC','ADDONS','STORAGE','DIAGNOSTICS'}
ADVANCED_FUNCTIONS = {'AppDnsGroup'}
row = re.compile(r'\b(ToggleRow|ChoiceRow|ActionRow|SettingRow)\(\s*"((?:[^"\\]|\\.)*)"(?:\s*,\s*(?:"((?:[^"\\]|\\.)*)"|null))?')
entries = []
for f in sorted(glob.glob(f'{D}/*.kt')):
    if f.endswith(('Controls.kt', 'SettingsRegistryData.kt', 'SettingsRegistry.kt')): continue
    text = open(f).read()
    for m in re.finditer(r'^(?:private |internal )?fun (?:[\w.]+\.)?(\w+)\(', text, re.M):
        name = m.group(1)
        if name not in PAGES: continue
        nxt = re.search(r'^(?:@Composable|fun |private fun |internal fun |/\*\*)', text[m.end():], re.M)
        body = text[m.start(): m.end() + (nxt.start() if nxt else len(text) - m.end())]
        lines = body.split('\n'); adv = set(); i = 0
        while i < len(lines):
            if re.search(r'AdvancedGroup\(c,|AdvancedToggle\s*\{', lines[i]):
                d = 0; j = i; started = False
                while j < len(lines):
                    d += lines[j].count('{') - lines[j].count('}'); started = started or '{' in lines[j]; adv.add(j)
                    if started and d <= 0: break
                    j += 1
                i = j
            i += 1
        for idx, l in enumerate(lines):
            for r in row.finditer(l):
                title, desc = r.group(2), r.group(3) or ''
                if '$' in title or not title: continue
                cat = PAGES[name]
                entries.append((cat, title, desc, 'ADVANCED' if (cat in ADVANCED_CATEGORIES or idx in adv or name in ADVANCED_FUNCTIONS) else 'ESSENTIAL'))
seen = set(); out = []
for e in entries:
    if (e[0], e[1]) not in seen: seen.add((e[0], e[1])); out.append(e)
slug = lambda t: re.sub(r'[^a-z0-9]+', '-', t.lower()).strip('-')[:48]
sens = re.compile(r'key|token|secret|password|pin\b|login|sign in|account', re.I)
stop = {'the','and','for','with','from','your','that','this','are','you','when','into','not','off','one'}
esc = lambda s: s.replace('$', '\\$')
ids = set(); rows = []
for cat, title, desc, exp in out:
    base = f'{cat.lower()}.{slug(title)}'; id_ = base; n = 2
    while id_ in ids: id_ = f'{base}-{n}'; n += 1
    ids.add(id_)
    kw = sorted(set(re.findall(r'[a-z0-9]{3,}', (title + ' ' + desc).lower())) - stop)[:10]
    rows.append(f'    SettingDef("{id_}", "{esc(title)}", "{esc(desc)}", Category.{cat}, Exposure.{exp}, listOf({", ".join(chr(34) + k + chr(34) for k in kw)}), {"true" if sens.search(title) else "false"}),')
head = '''package app.streamsetu.tv.ui.screens.settings

/**
 * Every control of Settings, listed once: its title, what it says, the page it is on, whether Essential shows it, what to search it by and whether it holds something private.
 * Written from the pages by scripts/gen_settings_registry.py and kept honest by SettingsRegistryCoverageTest, which fails when a page gains a control this list does not have.
 */
internal val SETTING_DEFS = listOf(
'''
open(f'{D}/SettingsRegistryData.kt', 'w').write(head + '\n'.join(rows) + '\n)\n')
print(len(rows), 'settings')
