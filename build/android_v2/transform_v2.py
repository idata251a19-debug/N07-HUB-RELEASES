from pathlib import Path
import re

root = Path(__import__('sys').argv[1]).resolve()
main = root / 'lib' / 'main.dart'
store = root / 'lib' / 'local_store.dart'
pub = root / 'pubspec.yaml'
manifest = root / 'AndroidManifest.xml'

s = main.read_text(encoding='utf-8')
# Remove V1 runtime endpoint/key constants without embedding their values here.
s = re.sub(r"^const String kSupabaseProjectUrl = .*?;\n", "", s, flags=re.M)
s = re.sub(r"^const String kSupabaseAnonKey = .*?;\n", "", s, flags=re.M)
s = re.sub(
    r"const String kSupabaseApiUrl = .*?;\nconst String kSupabaseHistoryUrl = .*?;\nconst String kSupabaseSyncUrl = .*?;\nconst String kBuiltInVfServerUrl = kSupabaseApiUrl;\nconst String kBuiltInAutoServerUrl = kSupabaseApiUrl;",
    "const String kOracleApiUrl = String.fromEnvironment(\n"
    "  'N07_V2_API_URL',\n"
    "  defaultValue: 'https://n07-v2.invalid/ords/n07v2/api',\n"
    ");\n"
    "const String kBuiltInVfServerUrl = kOracleApiUrl;\n"
    "const String kBuiltInAutoServerUrl = kOracleApiUrl;",
    s,
)
s = s.replace(
    "bool isValidAppsScriptWebUrl(String value) {\n  final clean = value.trim();\n  return clean.startsWith('https://') && clean.contains('/functions/v1/');\n}",
    "bool isValidOracleApiUrl(String value) {\n"
    "  final clean = value.trim();\n"
    "  if (!clean.startsWith('https://')) return false;\n"
    "  final uri = Uri.tryParse(clean);\n"
    "  return uri != null && uri.host.isNotEmpty && !uri.host.endsWith('.supabase.co');\n"
    "}",
)
s = s.replace('isValidAppsScriptWebUrl(', 'isValidOracleApiUrl(')
s = s.replace("'N07-${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(999999)}'", "'N07V2-${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(999999)}'")
s = s.replace("'n07_", "'n07_v2_")
s = s.replace('Future<Map<String, dynamic>> _edgePost(', 'Future<Map<String, dynamic>> _oraclePost(')
s = s.replace('_edgePost(', '_oraclePost(')
# Supabase-specific anonymous headers are not used by ORDS.
s = re.sub(r"\n\s*'apikey': kSupabaseAnonKey,", "", s)
s = re.sub(r"\n\s*'Authorization': 'Bearer \\$kSupabaseAnonKey',", "", s)
s = s.replace("'User-Agent': 'N07-HUBDNI-ANDROID/16.1.2-cloud-required'", "'User-Agent': 'N07-V2-ANDROID/2.0.0-cloud-required'\n              , 'X-N07-Client': 'ANDROID_V2'")
s = s.replace(
    "      if (response.statusCode >= 500) {\n        throw ApiException(\n          '${data['message'] ?? data['error'] ?? 'Supabase tạm bận.'}',\n          code: 'temporary_server',\n          data: data,\n        );\n      }",
    "      if (response.statusCode == 429 || response.statusCode >= 500) {\n"
    "        throw ApiException(\n"
    "          '${data['message'] ?? data['error'] ?? 'Oracle API tạm bận.'}',\n"
    "          code: 'temporary_server',\n"
    "          data: data,\n"
    "        );\n"
    "      }",
)
s = s.replace('kSupabaseApiUrl', 'kOracleApiUrl').replace('kSupabaseHistoryUrl', 'kOracleApiUrl').replace('kSupabaseSyncUrl', 'kOracleApiUrl')
s = s.replace('_publicUserFromSupabase', '_publicUserFromOracle').replace('_normalizeSupabaseError', '_normalizeOracleError')
s = s.replace('SUPABASE', 'ORACLE').replace('Supabase', 'Oracle').replace('supabase', 'oracle')
s = s.replace("'clientBuild': '3.3.3-reviewed'", "'clientBuild': 'N07-V2-ANDROID-2.0.0+1'")
s = s.replace(
    "      case 'USER_DISABLED': return 'account_disabled';\n      default: return raw.toLowerCase();",
    "      case 'USER_DISABLED': return 'account_disabled';\n"
    "      case 'ORACLE_DEADLOCK':\n"
    "      case 'ORACLE_LOCK_BUSY':\n"
    "      case 'TOO_MANY_REQUESTS': return 'temporary_server';\n"
    "      default: return raw.toLowerCase();",
)
s = s.replace(
    "  bool get configured => baseUrl.trim().startsWith('http');\n  bool get authConfigured => authBaseUrl.trim().startsWith('http');",
    "  bool get configured => isValidOracleApiUrl(baseUrl) && !baseUrl.contains('n07-v2.invalid');\n"
    "  bool get authConfigured => isValidOracleApiUrl(authBaseUrl) && !authBaseUrl.contains('n07-v2.invalid');",
)
main.write_text(s, encoding='utf-8')

s = store.read_text(encoding='utf-8')
s = s.replace("'n07_hub_auto_ev_v1.db'", "'n07_v2_auto_ev.db'")
s = s.replace("'n07_hub_offline_v4.db'", "'n07_v2_vf_e2w.db'")
s = s.replace('SUPABASE', 'ORACLE').replace('Supabase', 'Oracle').replace('supabase', 'oracle')
store.write_text(s, encoding='utf-8')

s = pub.read_text(encoding='utf-8')
s = s.replace('name: n07_hub_v1', 'name: n07_v2')
s = s.replace('description: N07 HUBDNI Android - field operations synchronized with N07 HUBDNI PC.', 'description: N07 V2 Android - field operations synchronized with N07 V2 Oracle canonical backend.')
s = s.replace('version: 16.1.2+52', 'version: 2.0.0+1')
pub.write_text(s, encoding='utf-8')
manifest.write_text(manifest.read_text(encoding='utf-8').replace('android:label="N07 HUBDNI"', 'android:label="N07 V2"'), encoding='utf-8')

# V2 source-only transport/isolation QA.
(root/'test'/'qa_android_v2_oracle_transport.py').write_text('''from pathlib import Path\nROOT=Path(__file__).resolve().parents[1]\nMAIN=(ROOT/'lib'/'main.dart').read_text()\nSTORE=(ROOT/'lib'/'local_store.dart').read_text()\nPUB=(ROOT/'pubspec.yaml').read_text()\nMAN=(ROOT/'AndroidManifest.xml').read_text()\ndef need(x,m):\n    if not x: raise AssertionError(m)\nneed('name: n07_v2' in PUB,'project identity')\nneed('version: 2.0.0+1' in PUB,'version')\nneed('android:label="N07 V2"' in MAN,'label')\nneed("'N07_V2_API_URL'" in MAIN,'Oracle API define')\nneed('_oraclePost(' in MAIN,'Oracle transport')\nneed("'n07_v2_device_id'" in MAIN,'prefs namespace')\nneed("'n07_v2_auto_ev.db'" in STORE and "'n07_v2_vf_e2w.db'" in STORE,'DB namespace')\nneed('response.statusCode == 429' in MAIN,'429 handling')\nneed("case 'ORACLE_DEADLOCK':" in MAIN and "case 'ORACLE_LOCK_BUSY':" in MAIN,'lock retry mapping')\nfor bad in ('adixvii','supabase.co','/functions/v1/','kSupabaseAnonKey','eyJhbGci','jdbc:','oracle.jdbc','DB_PASSWORD','TNS_ADMIN'):\n    need(bad.lower() not in MAIN.lower(), 'forbidden runtime marker '+bad)\nprint('PASS Android V2 Oracle transport + isolation')\n''', encoding='utf-8')

# Adapt authoritative cloud-required/uncertain tests to the new app identity only.
for name in ('qa_cloud_required_16_1_2.py','qa_uncertain_full_coverage_16_1_2.py'):
    p=root/'test'/name
    t=p.read_text(encoding='utf-8').replace('version: 16.1.2+52','version: 2.0.0+1').replace('PASS Android 16.1.2+52','PASS Android V2 2.0.0+1')
    p.write_text(t, encoding='utf-8')
# Current scanner authority is 16.0.6 behavior; adapt only the version assertion.
p=root/'test'/'qa_16_0_6_continuous_scan.py'
t=p.read_text(encoding='utf-8').replace("('version: 16.1.1+51' in pub)", "('version: 2.0.0+1' in pub)")
p.write_text(t, encoding='utf-8')

(root/'test'/'widget_test.dart').write_text("""import 'package:flutter_test/flutter_test.dart';\nimport 'package:n07_v2/main.dart';\nvoid main() {\n  test('V2 identity and warehouse parity', () {\n    expect(kWarehouseVf, 'VF_E2W');\n    expect(kWarehouseAuto, 'AUTO_EV');\n    expect(kBuiltInVfServerUrl, kOracleApiUrl);\n    expect(kBuiltInAutoServerUrl, kOracleApiUrl);\n    expect(kOracleApiUrl, isNot(contains('supabase.co')));\n  });\n  test('Android remains field-only', () {\n    expect(kAndroidFieldFeatures, contains('NHAP_PIN'));\n    expect(kAndroidFieldFeatures, contains('XUAT_PIN'));\n    expect(kAndroidFieldFeatures, isNot(contains('OFFLINE_SYNC')));\n    expect(kAndroidFieldFeatures.intersection(kPcOnlyFeatures), isEmpty);\n  });\n  test('QR comparison unchanged', () {\n    expect(qrCodesMatchExact('ABC123','ABC123'), isTrue);\n    expect(qrCodesMatchExact('ABC123','abc123'), isFalse);\n  });\n}\n""", encoding='utf-8')

# These are V1 backend/reference artifacts, not Android V2 runtime source.
for rel in ('n07-sync-v2.index.ts','lib/main.dart.baseline_16_0_6'):
    q=root/rel
    if q.exists(): q.unlink()
import shutil
q=root/'google_sheet_backend'
if q.exists(): shutil.rmtree(q)

# Hard fail if runtime source still contains V1 backend or direct DB material.
runtime=(main.read_text(encoding='utf-8')+'\n'+store.read_text(encoding='utf-8'))
for bad in ('adixvii','supabase.co','/functions/v1/','eyJhbGci','jdbc:','oracle.jdbc','DB_PASSWORD','TNS_ADMIN'):
    if bad.lower() in runtime.lower():
        raise SystemExit('forbidden runtime marker: '+bad)
print('TRANSFORM_V2_OK')
