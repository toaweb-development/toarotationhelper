#!/usr/bin/env python3
"""Simulates YOUR character's rotations in the MythicSim Forever engine.

1. In game, out of combat:  /toarot export   then  /reload
2. Here:  python3 tools/sim_character.py [--engine ~/tools/mythicsim-forever-engine] [--savedvariables FILE]

It reads the export from WTF/Account/*/SavedVariables/TOARotationHelper.lua, builds a MythicSim request
for that level, race, gear and talents, and runs the addon's own rotation lists (Rotations/Priest.lua,
mirrored below as MythicSim APLs). It prints raw DPS and "effective DPS" (damage per second including the
drinking needed to win back the mana spent), which is what decides how fast you level.

MythicSim only fires wands for hunters, so wand damage is added for the time a rotation does not cast:
idle seconds x wand DPS (from the item data) x Wand Specialization x 94 % hit.
"""
import argparse
import glob
import json
import os
import re
import subprocess
import sys

ADDON_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TALENT_TREE_SIZES = {'ClassPriest': [18, 17, 17]}
RACES = {
    'Human': 'RaceHuman', 'Dwarf': 'RaceDwarf', 'NightElf': 'RaceNightElf', 'Gnome': 'RaceGnome',
    'Orc': 'RaceOrc', 'Scourge': 'RaceUndead', 'Undead': 'RaceUndead', 'Tauren': 'RaceTauren',
    'Troll': 'RaceTroll', 'BloodElf': 'RaceBloodElf', 'Draenei': 'RaceDraenei',
}
# Water a levelling character drinks: (from level, mana over the 18 s drink).
WATER = [(1, 151), (5, 437), (15, 835), (25, 1344), (35, 1992), (45, 2934), (55, 4200)]
WAND_SPEC = {0: 1.0, 1: 1.13, 2: 1.25}
WAND_HIT = 0.94
TEMPLATE = 'fixtures/levels/holy-priest-L30.request.json'


# --- SavedVariables ---------------------------------------------------------------------------

def parse_lua_table(text):
    """Parses the subset of Lua the game writes to SavedVariables."""
    pos = 0

    def skip():
        nonlocal pos
        while pos < len(text):
            if text[pos].isspace() or text[pos] == ',' or text[pos] == ';':
                pos += 1
            elif text.startswith('--', pos):
                end = text.find('\n', pos)
                pos = len(text) if end < 0 else end + 1
            else:
                break

    def string():
        nonlocal pos
        quote = text[pos]
        pos += 1
        out = []
        while text[pos] != quote:
            if text[pos] == '\\':
                pos += 1
                out.append({'n': '\n', 't': '\t'}.get(text[pos], text[pos]))
            else:
                out.append(text[pos])
            pos += 1
        pos += 1
        return ''.join(out)

    def value():
        nonlocal pos
        skip()
        c = text[pos]
        if c == '{':
            pos += 1
            table, array = {}, []
            while True:
                skip()
                if text[pos] == '}':
                    pos += 1
                    break
                if text[pos] == '[':
                    pos += 1
                    key = value()
                    skip()
                    pos += 1  # ]
                    skip()
                    pos += 1  # =
                    table[key] = value()
                else:
                    m = re.match(r'([A-Za-z_]\w*)\s*=', text[pos:])
                    if m:
                        pos += m.end()
                        table[m.group(1)] = value()
                    else:
                        array.append(value())
            if array and not table:
                return array
            for i, v in enumerate(array, 1):
                table[i] = v
            return table
        if c in '"\'':
            return string()
        m = re.match(r'-?\d+(\.\d+)?([eE][-+]?\d+)?', text[pos:])
        if m:
            pos += m.end()
            return float(m.group(0)) if ('.' in m.group(0) or 'e' in m.group(0).lower()) else int(m.group(0))
        for word, val in (('true', True), ('false', False), ('nil', None)):
            if text.startswith(word, pos):
                pos += len(word)
                return val
        raise ValueError(f'cannot parse SavedVariables near: {text[pos:pos + 40]!r}')

    result = {}
    while True:
        skip()
        m = re.match(r'([A-Za-z_]\w*)\s*=', text[pos:])
        if not m:
            break
        pos += m.end()
        result[m.group(1)] = value()
    return result


def find_savedvariables(path):
    if path:
        return path
    wtf = os.path.normpath(os.path.join(ADDON_DIR, '..', '..', '..', 'WTF', 'Account'))
    files = glob.glob(os.path.join(wtf, '*', 'SavedVariables', 'TOARotationHelper.lua'))
    if not files:
        sys.exit(f'No TOARotationHelper.lua under {wtf}. Run /toarot export and /reload in game first.')
    return max(files, key=os.path.getmtime)


def as_list(v, n=None):
    if isinstance(v, dict):
        v = [v.get(i) for i in range(1, (n or max([k for k in v if isinstance(k, int)] or [0])) + 1)]
    return list(v or [])


# --- Request ------------------------------------------------------------------------------------

def talent_string(engine, class_name, talents):
    schema_text = open(os.path.join(engine, 'data', 'proto-schema.json')).read()
    schema = json.loads(schema_text)
    proto = {'ClassPriest': 'proto.PriestTalents'}[class_name]
    fields = None
    if isinstance(schema, dict) and proto in schema:
        fields = schema[proto]['fields']
    else:
        for block in (schema if isinstance(schema, list) else schema.values()):
            if isinstance(block, dict) and proto in block:
                fields = block[proto]['fields']
                break
    if fields is None:
        start = schema_text.find(f'"{proto}"')
        fields = json.loads('{' + schema_text[start:].split('}]', 1)[0] + '}]}}')[proto]['fields']
    by_name = {f['name']: f['number'] for f in fields}
    sizes = TALENT_TREE_SIZES[class_name]
    trees = [[0] * s for s in sizes]
    unknown = []
    for name, rank in (talents or {}).items():
        key = re.sub(r'[^a-z0-9]+', '_', name.lower()).strip('_')
        number = by_name.get(key)
        if not number or not rank:
            if rank and not number:
                unknown.append(name)
            continue
        index = number - 1
        for t, size in enumerate(sizes):
            if index < size:
                trees[t][index] = int(rank)
                break
            index -= size
    if unknown:
        print(f'note: talents MythicSim does not model: {", ".join(sorted(unknown))}')
    return '-'.join(''.join(str(d) for d in tree).rstrip('0') for tree in trees).rstrip('-')


# Item stat numbers (proto.Stat) for the five attributes: strength, agility, stamina, intellect, spirit.
ATTRIBUTE_STATS = ['0', '1', '2', '3', '16']


def gear_attributes(engine, items):
    """Sum of the five attributes the equipped items and their enchants give."""
    wanted = {it['id']: it.get('enchant') for it in items if it.get('id')}
    totals = [0, 0, 0, 0, 0]
    seen = set()
    for name in ('forever-live-items.jsonl', 'forever-client-items.jsonl', 'items.jsonl'):
        for line in open(os.path.join(engine, 'data', name)):
            it = json.loads(line)
            if it.get('id') in wanted and it['id'] not in seen:
                seen.add(it['id'])
                stats = (it.get('scaling_options', {}).get('0') or {}).get('stats') or {}
                for i, key in enumerate(ATTRIBUTE_STATS):
                    totals[i] += stats.get(key, 0)
    enchants = {e for e in wanted.values() if e}
    for line in open(os.path.join(engine, 'data', 'enchants.jsonl')):
        e = json.loads(line)
        if e.get('effect_id') in enchants:
            stats = e.get('stats') or []
            for i, key in enumerate(ATTRIBUTE_STATS):
                k = int(key)
                totals[i] += stats[k] if k < len(stats) else 0
    missing = set(wanted) - seen
    if missing:
        print(f'note: no item data for {sorted(missing)}; their stats stay in the base attributes')
    return totals


def base_attributes(engine, export, items):
    """Forever's UnitStat returns the total twice, so the base is the total minus gear and enchants."""
    attributes = [int(x or 0) for x in as_list(export.get('attributes'), 5)]
    base = [int(x or 0) for x in as_list(export.get('base'), 5)]
    if base != attributes:
        return base
    gear = gear_attributes(engine, items)
    return [max(1, a - g) for a, g in zip(attributes, gear)]


def build_request(engine, export):
    d = json.load(open(os.path.join(engine, TEMPLATE)))
    p = d['raid']['parties'][0]['players'][0]
    level = int(export['level'])
    items = [dict(it) if isinstance(it, dict) else {} for it in as_list(export.get('equipment'), 17)]
    items = [{k: int(v) for k, v in it.items() if k in ('id', 'enchant')} for it in items]
    p['level'] = level
    p['race'] = RACES.get(export.get('race'), 'RaceHuman')
    p['class'] = 'ClassPriest'
    p['equipment'] = {'items': items}
    p['characterSheet'] = {
        'attributes': [int(x or 0) for x in as_list(export.get('attributes'), 5)],
        'base': base_attributes(engine, export, items),
        'equipment': {'items': items},
        'health': int(export.get('health') or 0),
        'level': level,
        'mana': int(export.get('mana') or 0),
        'meleeCrit': float(export.get('meleeCrit') or 0),
        'spellCrit': [float(x or 0) for x in as_list(export.get('spellCrit'), 6)],
    }
    p['knownSpells'] = [int(x) for x in as_list(export.get('knownSpells'))]
    p['talentsString'] = talent_string(engine, 'ClassPriest', export.get('talents'))
    p.pop('healerPriest', None)
    p['dpsPriest'] = {'options': {'classOptions': {}}}
    target = d['encounter']['targets'][0]
    target['level'] = level + 2
    target['name'] = f'Level {level + 2}'
    d['encounter']['durationVariation'] = 0
    return d, p['talentsString']


# --- Rotations (mirror of Rotations/Priest.lua) --------------------------------------------------

def sid(i, rank=None):
    return {'spellId': i, **({'rank': rank} if rank else {})}

SPELL = {'smite': (10934, 8), 'smite2': (591, 2), 'swp': (10894, 8), 'hf': (15261, 8), 'mb': (10947, 9),
         'dp': (19280, 6), 'mf': (18807, 6), 'swd': (1309636, 4), 'if': (14751, None), 'sf': (15473, None)}

def cast(name, cond=None):
    a = {'castSpell': {'spellId': sid(*SPELL[name])}}
    if cond:
        a['condition'] = cond
    return {'action': a}

def shoot():
    return {'action': {'castSpell': {'spellId': {'otherId': 'OtherActionShoot'}}}}

def mana_ge(p):
    return {'cmp': {'op': 'OpGe', 'lhs': {'currentManaPercent': {}}, 'rhs': {'const': {'val': f'{p}%'}}}}

def dot_lt(name, s):
    return {'cmp': {'op': 'OpLt', 'lhs': {'dotRemainingTime': {'spellId': sid(*SPELL[name])}},
                    'rhs': {'const': {'val': f'{s}s'}}}}

def not_dot(name):
    return {'not': {'val': {'dotIsActive': {'spellId': sid(*SPELL[name])}}}}

def both(a, b):
    return {'and': {'vals': [a, b]}}

def rotations(save=20):
    rich = mana_ge(save)
    smite = [
        {'action': {'strictSequence': {'actions': [{'castSpell': {'spellId': sid(*SPELL['if'])}},
                                                   {'castSpell': {'spellId': sid(*SPELL['hf'])}}]},
                    'condition': both(dot_lt('hf', 3), rich)}},
        cast('swp', not_dot('swp')), cast('dp'), cast('hf', both(dot_lt('hf', 3), rich)),
        cast('mb', rich), cast('smite', rich), cast('smite2'), cast('smite'), shoot(),
    ]
    shadow = [
        cast('swp', not_dot('swp')), cast('dp'),
        {'action': {'strictSequence': {'actions': [{'castSpell': {'spellId': sid(*SPELL['if'])}},
                                                   {'castSpell': {'spellId': sid(*SPELL['mb'])}}]}}},
        cast('mb'), cast('swd'), cast('mf'), cast('smite'), shoot(),
    ]
    # Nothing may follow shoot(): MythicSim skips Shoot for casters and would fall through to the next
    # line, turning the wand list into Smite spam. Idle time is turned into wand damage afterwards.
    wand = [cast('swp', not_dot('swp')), cast('mb'), shoot()]
    return {'smite': (smite, []), 'shadow': (shadow, [cast('sf')]), 'wand': (wand, [])}


# --- Running ------------------------------------------------------------------------------------

def wand_dps(engine, item_id, wand_spec_rank):
    if not item_id:
        return 0.0
    for name in ('items.jsonl', 'forever-client-items.jsonl'):
        for line in open(os.path.join(engine, 'data', name)):
            it = json.loads(line)
            if it.get('id') == item_id and it.get('ranged_weapon_type') == 'RangedWeaponTypeWand':
                o = it['scaling_options']['0']
                dps = (o['weapon_damage_min'] + o['weapon_damage_max']) / 2 / it['weapon_speed']
                return dps * WAND_SPEC.get(wand_spec_rank, 1.0)
    return 0.0


def busy_seconds(engine):
    busy = {}
    for line in open(os.path.join(engine, 'data', 'spells.jsonl')):
        s = json.loads(line)
        t = max((s.get('CastTimeMs') or 0) / 1000, (s.get('GCDMs') or 1500) / 1000)
        if s.get('Name') in ('Mind Flay', 'Penance'):
            t = max(t, (s.get('DurationMs') or 2000) / 1000)
        busy[s['ID']] = t
    return busy


def run(engine, request, rotation, prepull, duration, iterations, out_dir, tag):
    d = json.loads(json.dumps(request))
    p = d['raid']['parties'][0]['players'][0]
    p['rotation'] = {'type': 'TypeAPL', 'prepullActions': [
        {'action': a['action'], 'doAtValue': {'const': {'val': '-1.5s'}}} for a in prepull],
        'priorityList': rotation}
    d['encounter']['duration'] = duration
    d['simOptions']['iterations'] = iterations
    req, res = os.path.join(out_dir, tag + '.request.json'), os.path.join(out_dir, tag + '.result.json')
    json.dump(d, open(req, 'w'))
    r = subprocess.run([os.path.join(engine, 'target', 'release', 'forever-engine'), 'sim', '--request', req,
                        '--outfile', res], capture_output=True, text=True, timeout=600)
    if r.returncode:
        return None, (r.stdout + r.stderr).strip()[-400:]
    result = json.load(open(res))['result']
    return result, None


def summarize(result, duration, busy, wand, uses_wand):
    n = result['iterationsDone']
    pl = result['raidMetrics']['parties'][0]['players'][0]
    spent = -sum(r.get('actualGain', 0) for r in pl['resources'] if r['type'] == 'ResourceTypeMana') / n
    cast_time = 0.0
    for a in pl['actions']:
        spell = a['id'].get('spellId')
        casts = sum(t.get('casts', 0) for t in a.get('targets', [])) / n
        if spell in busy and casts:
            cast_time += casts * busy[spell]
    idle = max(0.0, duration - cast_time) if uses_wand else 0.0
    dps = pl['dps']['avg'] + idle * wand * WAND_HIT / duration
    return dps, max(0.0, spent)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--engine', default=os.path.expanduser('~/tools/mythicsim-forever-engine'))
    ap.add_argument('--savedvariables')
    ap.add_argument('--iterations', type=int, default=1000)
    ap.add_argument('--durations', default='30,90')
    ap.add_argument('--out', default=os.path.expanduser('~/tools/toarot-sims'))
    args = ap.parse_args()

    sv = parse_lua_table(open(find_savedvariables(args.savedvariables), encoding='utf-8').read())
    export = (sv.get('TOARotationHelperDB') or {}).get('export')
    if not export:
        sys.exit('No export in SavedVariables. In game: /toarot export, then /reload.')
    if export.get('class') != 'PRIEST':
        sys.exit(f'Only Priest is supported so far (export is {export.get("class")}).')
    os.makedirs(args.out, exist_ok=True)

    request, talents = build_request(args.engine, export)
    level = int(export['level'])
    drink = max(m for lvl, m in WATER if lvl <= level) / 18
    ranged = as_list(export.get('equipment'), 17)[16] or {}
    wand_rank = int((export.get('talents') or {}).get('Wand Specialization', 0) or 0)
    wand = wand_dps(args.engine, (ranged or {}).get('id'), wand_rank)
    busy = busy_seconds(args.engine)

    print(f'Level {level} {export.get("race")} priest, talents {talents or "(none)"} '
          f'(read with: {export.get("talentMethod")}), wand {wand:.1f} DPS, drink {drink:.0f} mana/s')
    durations = [int(x) for x in args.durations.split(',')]
    header = ''.join(f'{f"{d}s DPS / effective":>26}' for d in durations)
    print(f'{"rotation":10s}{header}')
    best = None
    for name, (lines, prepull) in rotations().items():
        if name == 'wand' and wand <= 0:
            print('wand      no wand equipped: skipped')
            continue
        cells = []
        score = 0.0
        for dur in durations:
            result, err = run(args.engine, request, lines, prepull, dur, args.iterations, args.out, f'{name}-{dur}')
            if not result:
                cells.append('refused')
                print(f'  {name} {dur}s: {err}')
                continue
            uses_wand = any('OtherActionShoot' in json.dumps(l) for l in lines)
            dps, spent = summarize(result, dur, busy, wand, uses_wand)
            eff = dps * dur / (dur + spent / drink)
            score += eff
            cells.append(f'{dps:8.1f} / {eff:6.1f}')
        print(f'{name:10s}' + ''.join(f'{c:>26}' for c in cells))
        if best is None or score > best[1]:
            best = (name, score)
    if best:
        print(f'\nFastest levelling for this character: {best[0]}   (in game: /toarot mode {best[0]})')


if __name__ == '__main__':
    main()
