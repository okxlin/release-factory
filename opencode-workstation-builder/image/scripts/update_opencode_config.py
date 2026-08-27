#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path

CONFIG_DIRS = [
    Path(os.environ.get('OPENCODE_CONFIG_DIR', '')).expanduser() if os.environ.get('OPENCODE_CONFIG_DIR') else None,
    Path('/config/opencode'),
    Path.home() / '.config' / 'opencode',
]

CONFIG_FILES = ['opencode.json', 'opencode.jsonc']
USER_CONFIG_FILES = ['opencode.user.json', 'opencode.user.jsonc']
DEPRECATED_PLUGIN_BASES = {'opencode-gpt-unlocked'}
DEPRECATED_EXPERIMENTAL_KEYS = {'refusal_patcher'}


def resolve_config_dir() -> Path | None:
    env_dir = os.environ.get('OPENCODE_CONFIG_DIR', '').strip()
    if env_dir:
        return Path(env_dir).expanduser()
    for directory in CONFIG_DIRS[1:]:
        if directory and directory.exists():
            return directory
    for directory in CONFIG_DIRS[1:]:
        if directory:
            return directory
    return None


def strip_jsonc(text: str) -> str:
    lines = []
    for line in text.splitlines():
        out = []
        in_string = False
        escaped = False
        i = 0
        while i < len(line):
            ch = line[i]
            if escaped:
                out.append(ch)
                escaped = False
            elif ch == '\\':
                out.append(ch)
                escaped = True
            elif ch == '"':
                out.append(ch)
                in_string = not in_string
            elif not in_string and ch == '/' and i + 1 < len(line) and line[i + 1] == '/':
                break
            else:
                out.append(ch)
            i += 1
        lines.append(''.join(out))
    return '\n'.join(lines)


def load_config(path: Path):
    if not path.exists():
        return {}
    raw = path.read_text(encoding='utf-8')
    cleaned = strip_jsonc(raw).strip()
    return json.loads(cleaned) if cleaned else {}


def save_config(path: Path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')


def locate_config() -> Path:
    preferred_dir = resolve_config_dir()
    if preferred_dir:
        for filename in CONFIG_FILES:
            path = preferred_dir / filename
            if path.exists():
                return path
        return preferred_dir / 'opencode.json'
    for directory in CONFIG_DIRS:
        if not directory:
            continue
        for filename in CONFIG_FILES:
            path = directory / filename
            if path.exists():
                return path
    for directory in CONFIG_DIRS:
        if directory:
            return directory / 'opencode.json'
    return Path.home() / '.config' / 'opencode' / 'opencode.json'


def locate_user_config(config_path: Path) -> Path | None:
    for filename in USER_CONFIG_FILES:
        candidate = config_path.parent / filename
        if candidate.exists():
            return candidate
    return None


def merge_plugin_lists(base_plugins, overlay_plugins):
    merged = []
    seen = set()
    for item in list(base_plugins) + list(overlay_plugins):
        key = json.dumps(item, sort_keys=True, ensure_ascii=False) if isinstance(item, (dict, list)) else str(item)
        if key in seen:
            continue
        seen.add(key)
        merged.append(item)
    return merged


def deep_merge(base, overlay, path=()):
    if isinstance(base, dict) and isinstance(overlay, dict):
        merged = dict(base)
        for key, value in overlay.items():
            merged[key] = deep_merge(base.get(key), value, path + (key,))
        return merged
    if path == ('plugin',):
        base_plugins = base if isinstance(base, list) else []
        overlay_plugins = overlay if isinstance(overlay, list) else []
        return merge_plugin_lists(base_plugins, overlay_plugins)
    return overlay


def apply_user_overrides(data, config_path: Path):
    user_config_path = locate_user_config(config_path)
    if not user_config_path:
        return data
    user_data = load_config(user_config_path)
    if not isinstance(user_data, dict):
        return data
    return deep_merge(data, user_data)


def ensure_plugin(data, plugin_name):
    plugins = data.get('plugin')
    if not isinstance(plugins, list):
        plugins = []
    normalized = {plugin_base_name(item) for item in plugins}
    plugin_base = plugin_base_name(plugin_name)
    if plugin_base not in normalized and plugin_name not in plugins:
        plugins.append(plugin_name)
    data['plugin'] = plugins


def package_base_name(value):
    if value.startswith('@'):
        separator = value.find('@', 1)
        return value[:separator] if separator > 0 else value
    return value.split('@', 1)[0]


def plugin_base_name(item):
    if isinstance(item, str):
        return package_base_name(item)
    if isinstance(item, (list, tuple)) and item and isinstance(item[0], str):
        return package_base_name(item[0])
    if isinstance(item, dict):
        for key in ('package', 'name'):
            value = item.get(key)
            if isinstance(value, str):
                return package_base_name(value)
    return None


def remove_deprecated_entries(data):
    removed = []
    plugins = data.get('plugin')
    if isinstance(plugins, list):
        kept_plugins = []
        for item in plugins:
            if plugin_base_name(item) in DEPRECATED_PLUGIN_BASES:
                removed.append('plugin:opencode-gpt-unlocked')
            else:
                kept_plugins.append(item)
        if len(kept_plugins) != len(plugins):
            data['plugin'] = kept_plugins

    experimental = data.get('experimental')
    if isinstance(experimental, dict):
        for key in DEPRECATED_EXPERIMENTAL_KEYS:
            if key in experimental:
                del experimental[key]
                removed.append(f'experimental:{key}')
        if not experimental:
            data.pop('experimental', None)
    return removed


def ensure_oh_my_opencode_registration(data):
    mcp = data.get('mcp')
    if not isinstance(mcp, dict):
        mcp = {}
    if 'oh-my-opencode' not in mcp:
        mcp['oh-my-opencode'] = {
            'type': 'local',
            'command': ['bunx', '--bun', 'oh-my-opencode', 'mcp', 'start'],
            'enabled': True,
        }
    data['mcp'] = mcp


def detect_provider_id() -> str:
    provider = os.environ.get('OPENCODE_PROVIDER_ID', '').strip()
    if provider:
        return provider
    for key in ('OPENCODE_MODEL', 'OPENCODE_SMALL_MODEL'):
        value = os.environ.get(key, '').strip()
        if '/' in value:
            provider_id = value.split('/', 1)[0].strip()
            if provider_id:
                return provider_id
    return 'openai'


def detect_provider_base_url(provider_id: str) -> str:
    provider_env_map = {
        'openai': 'OPENAI_BASE_URL',
        'anthropic': 'ANTHROPIC_BASE_URL',
        'openrouter': 'OPENROUTER_BASE_URL',
        'google': 'GEMINI_BASE_URL',
        'gemini': 'GEMINI_BASE_URL',
        'mimo': 'OPENAI_BASE_URL',
        'xiaomi': 'OPENAI_BASE_URL',
    }
    env_key = provider_env_map.get(provider_id)
    if not env_key:
        return ''
    return os.environ.get(env_key, '').strip()


def ensure_model_settings(data):
    model = os.environ.get('OPENCODE_MODEL', '').strip()
    small_model = os.environ.get('OPENCODE_SMALL_MODEL', '').strip()
    provider_id = detect_provider_id()
    provider_base_url = detect_provider_base_url(provider_id)

    if model:
        data['model'] = model
    if small_model:
        data['small_model'] = small_model

    if provider_base_url:
        providers = data.get('provider')
        if not isinstance(providers, dict):
            providers = {}
        provider_config = providers.get(provider_id)
        if not isinstance(provider_config, dict):
            provider_config = {}
        options = provider_config.get('options')
        if not isinstance(options, dict):
            options = {}
        options['baseURL'] = provider_base_url
        api_key = os.environ.get('OPENAI_API_KEY', '').strip() if provider_id in {'openai', 'mimo', 'xiaomi'} else ''
        if api_key:
            options['apiKey'] = api_key
        provider_config['options'] = options
        providers[provider_id] = provider_config
        data['provider'] = providers


def ensure_extra_plugins(data):
    raw = os.environ.get('OPENCODE_EXTRA_PLUGINS', '').strip()
    if not raw:
        return
    for plugin_name in [item.strip() for item in raw.split(',') if item.strip()]:
        ensure_plugin(data, plugin_name)


def main():
    if len(sys.argv) < 2:
        raise SystemExit('usage: update_opencode_config.py migrate-deprecated | plugin <plugin-name> | oh-my-opencode register | sync-model')
    action = sys.argv[1]
    value = sys.argv[2] if len(sys.argv) >= 3 else None
    path = locate_config()
    if action == 'migrate-deprecated':
        if path.exists():
            data = load_config(path)
            removed = remove_deprecated_entries(data)
            if removed:
                save_config(path, data)
                print(f"removed deprecated OpenCode entries: {', '.join(sorted(set(removed)))}", file=sys.stderr)
        print(path)
        return
    data = load_config(path)
    if action == 'plugin':
        if not value:
            raise SystemExit('usage: update_opencode_config.py plugin <plugin-name>')
        ensure_plugin(data, value)
        ensure_model_settings(data)
        ensure_extra_plugins(data)
    elif action == 'oh-my-opencode' and value == 'register':
        ensure_oh_my_opencode_registration(data)
        ensure_model_settings(data)
        ensure_extra_plugins(data)
    elif action == 'sync-model':
        ensure_model_settings(data)
    else:
        suffix = f' {value}' if value is not None else ''
        raise SystemExit(f'unknown action: {action}{suffix}')
    data = apply_user_overrides(data, path)
    removed = remove_deprecated_entries(data)
    if removed:
        print(f"removed deprecated OpenCode entries: {', '.join(sorted(set(removed)))}", file=sys.stderr)
    save_config(path, data)
    print(path)


if __name__ == '__main__':
    main()
