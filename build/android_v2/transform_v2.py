from pathlib import Path
import re, shutil, sys

root = Path(sys.argv[1]).resolve()
main = root / 'lib' / 'main.dart'
store = root / 'lib' / 'local_store.dart'
pub = root / 'pubspec.yaml'
manifest = root / 'AndroidManifest.xml'

s = main.read_text(encoding='utf-8')
# Remove V1 runtime endpoint/key constants without embedding secret values here.
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
old_headers = """            headers: const {
              'Accept': 'application/json',
              'Content-Type': 'application/json; charset=utf-8',
              'apikey': kSupabaseAnonKey,
              'Authorization': 'Bearer $kSupabaseAnonKey',
              'User-Agent': 'N07-HUBDNI-ANDROID/16.1.2-cloud-required',
            },"""
new_headers = """            headers: const {
              'Accept': 'application/json',
              'Content-Type': 'application/json; charset=utf-8',
              'User-Agent': 'N07-V2-ANDROID/2.0.0-cloud-required',
              'X-N07-Client': 'ANDROID_V2',
            },"""
if old_headers not in s:
    raise SystemExit('V1 HTTP header block not found')
s = s.replace(old_headers, new_headers, 1)
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

# Adapt authoritative cloud-required/uncertain tests only for the new identity.
for name in ('qa_cloud_required_16_1_2.py', 'qa_uncertain_full_coverage_16_1_2.py'):
    p = root / 'test' / name
    t = p.read_text(encoding='utf-8').replace('version: 16.1.2+52', 'version: 2.0.0+1').replace('PASS Android 16.1.2+52', 'PASS Android V2 2.0.0+1')
    p.write_text(t, encoding='utf-8')

(root/'test'/'qa_android_v2_oracle_transport.py').write_text(r'''from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
MAIN=(ROOT/'lib'/'main.dart').read_text()
STORE=(ROOT/'lib'/'local_store.dart').read_text()
PUB=(ROOT/'pubspec.yaml').read_text()
MAN=(ROOT/'AndroidManifest.xml').read_text()
def need(x,m):
    if not x: raise AssertionError(m)
need('name: n07_v2' in PUB,'project identity')
need('version: 2.0.0+1' in PUB,'version')
need('android:label="N07 V2"' in MAN,'label')
need("'N07_V2_API_URL'" in MAIN,'Oracle API define')
need('_oraclePost(' in MAIN,'Oracle transport')
need("'n07_v2_device_id'" in MAIN,'prefs namespace')
need("'n07_v2_session_token'" in MAIN,'session namespace')
need("'n07_v2_auto_ev.db'" in STORE and "'n07_v2_vf_e2w.db'" in STORE,'DB namespace')
need('response.statusCode == 429' in MAIN,'429 handling')
need("case 'ORACLE_DEADLOCK':" in MAIN and "case 'ORACLE_LOCK_BUSY':" in MAIN,'lock retry mapping')
for bad in ('adixvii','supabase.co','/functions/v1/','kSupabaseAnonKey','eyJhbGci','jdbc:','oracle.jdbc','DB_PASSWORD','TNS_ADMIN'):
    need(bad.lower() not in MAIN.lower(), 'forbidden runtime marker '+bad)
print('PASS Android V2 Oracle transport + isolation')
''', encoding='utf-8')

(root/'test'/'qa_android_v2_scanner.py').write_text(r'''from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
MAIN=(ROOT/'lib'/'main.dart').read_text()
PUB=(ROOT/'pubspec.yaml').read_text()
def need(x,m):
    if not x: raise AssertionError(m)
need('version: 2.0.0+1' in PUB,'V2 version')
need('void _armScannerInputWithRetries()' in MAIN,'scanner rearm helper')
need('_manualTextFocus.requestFocus();' in MAIN,'scanner TextField focus')
need('widget.onSubmitted(value);\n          _returnToScannerMode();' in MAIN,'submit keeps scanner mode')
need('onTapOutside: (_) => _returnToScannerMode()' in MAIN,'tap outside returns scanner mode')
need('bool _hardwareSessionStarted = false;' not in MAIN,'obsolete hardware session path returned')
need('keyboardType: TextInputType.text' in MAIN,'scanner TextField changed input type')
need('LogicalKeyboardKey.enter' in MAIN and 'LogicalKeyboardKey.numpadEnter' in MAIN and 'LogicalKeyboardKey.tab' in MAIN,'hardware terminators changed')
print('PASS Android V2 scanner behavior preserved')
''', encoding='utf-8')

(root/'test'/'widget_test.dart').write_text("""import 'package:flutter_test/flutter_test.dart';
import 'package:n07_v2/main.dart';
void main() {
  test('V2 identity and warehouse parity', () {
    expect(kWarehouseVf, 'VF_E2W');
    expect(kWarehouseAuto, 'AUTO_EV');
    expect(kBuiltInVfServerUrl, kOracleApiUrl);
    expect(kBuiltInAutoServerUrl, kOracleApiUrl);
    expect(kOracleApiUrl, isNot(contains('supabase.co')));
  });
  test('Android remains field-only', () {
    expect(kAndroidFieldFeatures, contains('NHAP_PIN'));
    expect(kAndroidFieldFeatures, contains('XUAT_PIN'));
    expect(kAndroidFieldFeatures, isNot(contains('OFFLINE_SYNC')));
    expect(kAndroidFieldFeatures.intersection(kPcOnlyFeatures), isEmpty);
  });
  test('QR comparison unchanged', () {
    expect(qrCodesMatchExact('ABC123','ABC123'), isTrue);
    expect(qrCodesMatchExact('ABC123','abc123'), isFalse);
  });
}
""", encoding='utf-8')

# Remove V1 backend/reference artifacts from V2 source artifact.
for rel in ('n07-sync-v2.index.ts', 'lib/main.dart.baseline_16_0_6'):
    q = root / rel
    if q.exists(): q.unlink()
q = root / 'google_sheet_backend'
if q.exists(): shutil.rmtree(q)

runtime = main.read_text(encoding='utf-8') + '\n' + store.read_text(encoding='utf-8')
for bad in ('adixvii','supabase.co','/functions/v1/','eyJhbGci','jdbc:','oracle.jdbc','DB_PASSWORD','TNS_ADMIN'):
    if bad.lower() in runtime.lower():
        raise SystemExit('forbidden runtime marker: '+bad)
print('TRANSFORM_V2_OK')
