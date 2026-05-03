#!/usr/bin/env python3
import copy
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


def ensure_plugin(data, plugin_name):
    plugins = data.get('plugin')
    if not isinstance(plugins, list):
        plugins = []
    normalized = {str(item).split('@')[0] for item in plugins if isinstance(item, str)}
    plugin_base = plugin_name.split('@')[0]
    if plugin_base not in normalized and plugin_name not in plugins:
        plugins.append(plugin_name)
    data['plugin'] = plugins


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


def ensure_refusal_settings(data):
    experimental = data.get('experimental')
    if not isinstance(experimental, dict):
        experimental = {}
    refusal = experimental.get('refusal_patcher')
    if not isinstance(refusal, dict):
        refusal = {}
    refusal.setdefault('enabled', True)
    base_url = os.environ.get('GPT_UNLOCKED_BASE_URL', '').strip()
    api_key = os.environ.get('GPT_UNLOCKED_API_KEY', '').strip()
    model = os.environ.get('GPT_UNLOCKED_MODEL', '').strip()
    placeholder = os.environ.get('GPT_UNLOCKED_PLACEHOLDER', '').strip()
    if base_url:
        refusal['base_url'] = base_url
    if api_key:
        refusal['api_key'] = api_key
    if model:
        refusal['model'] = model
    if placeholder:
        refusal['placeholder'] = placeholder
    experimental['refusal_patcher'] = refusal
    data['experimental'] = experimental


def ensure_model_settings(data):
    model = os.environ.get('OPENCODE_MODEL', '').strip()
    small_model = os.environ.get('OPENCODE_SMALL_MODEL', '').strip()
    provider_id = os.environ.get('OPENCODE_PROVIDER_ID', '').strip()
    if model:
        data['model'] = model
    if small_model:
        data['small_model'] = small_model
    provider_map = {
        'openai': ('OPENAI_BASE_URL', 'OPENAI_API_KEY'),
        'anthropic': ('ANTHROPIC_BASE_URL', 'ANTHROPIC_API_KEY'),
        'openrouter': ('OPENROUTER_BASE_URL', 'OPENROUTER_API_KEY'),
        'gemini': ('GEMINI_BASE_URL', 'GEMINI_API_KEY'),
        'gpt-unlocked': ('GPT_UNLOCKED_BASE_URL', 'GPT_UNLOCKED_API_KEY'),
        'mimo': ('OPENAI_BASE_URL', 'OPENAI_API_KEY'),
        'xiaomi': ('OPENAI_BASE_URL', 'OPENAI_API_KEY'),
    }
    if provider_id:
        provider = data.get('provider')
        if not isinstance(provider, dict):
            provider = {}
        provider_entry = provider.get(provider_id)
        if not isinstance(provider_entry, dict):
            provider_entry = {}
        options = provider_entry.get('options')
        if not isinstance(options, dict):
            options = {}
        base_env, key_env = provider_map.get(provider_id, ('', ''))
        base_url = os.environ.get(base_env, '').strip() if base_env else ''
        api_key = os.environ.get(key_env, '').strip() if key_env else ''
        if base_url:
            options['baseURL'] = base_url
        if api_key:
            options['apiKey'] = api_key
        if options:
            provider_entry['options'] = options
        if provider_entry:
            provider[provider_id] = provider_entry
        if provider:
            data['provider'] = provider


def merge_values(base, override):
    if isinstance(base, dict) and isinstance(override, dict):
        result = {k: copy.deepcopy(v) for k, v in base.items()}
        for key, value in override.items():
            if key in result:
                result[key] = merge_values(result[key], value)
            else:
                result[key] = copy.deepcopy(value)
        return result
    if isinstance(base, list) and isinstance(override, list):
        if all(isinstance(v, str) for v in base + override):
            merged = []
            seen = set()
            for item in base + override:
                if item in seen:
                    continue
                seen.add(item)
                merged.append(item)
            return merged
        return copy.deepcopy(base) + copy.deepcopy(override)
    return copy.deepcopy(override)


def apply_user_override(data, config_path: Path):
    user_override = config_path.with_name('opencode.user.json')
    if user_override.exists():
        override_data = load_config(user_override)
        if isinstance(override_data, dict):
            return merge_values(data, override_data)
    return data


def main():
    if len(sys.argv) < 2:
        raise SystemExit('usage: update_opencode_config.py plugin <plugin-name> | oh-my-opencode register | sync-model')
    action = sys.argv[1]
    value = sys.argv[2] if len(sys.argv) >= 3 else None
    path = locate_config()
    data = load_config(path)
    if action == 'plugin':
        if not value:
            raise SystemExit('usage: update_opencode_config.py plugin <plugin-name>')
        ensure_plugin(data, value)
        if value.startswith('opencode-gpt-unlocked'):
            ensure_refusal_settings(data)
    elif action == 'oh-my-opencode' and value == 'register':
        ensure_oh_my_opencode_registration(data)
    elif action == 'sync-model':
        pass
    else:
        suffix = f' {value}' if value is not None else ''
        raise SystemExit(f'unknown action: {action}{suffix}')
    ensure_model_settings(data)
    data = apply_user_override(data, path)
    save_config(path, data)
    print(path)


if __name__ == '__main__':
    main()
