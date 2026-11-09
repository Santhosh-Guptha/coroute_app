import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:http/http.dart' as http;

import '../../../data/services/api_client.dart';
import '../../../domain/marketing/marketing_template.dart';

/// A row of the template list (GET /admin/marketing/templates).
class MkTemplateSummary {
  final String id;
  final String name;
  final String status;
  final MkSize size;
  final String? couponCode;
  final int layerCount;
  final int? updatedAt;
  final String? updatedBy;

  const MkTemplateSummary({required this.id, required this.name, required this.status, required this.size, this.couponCode, this.layerCount = 0, this.updatedAt, this.updatedBy});

  static MkTemplateSummary? fromJson(Object? raw) {
    if (raw is! Map || (raw['id']?.toString() ?? '').isEmpty) return null;
    return MkTemplateSummary(
      id: raw['id'].toString(),
      name: raw['name']?.toString() ?? 'Untitled',
      status: raw['status']?.toString() ?? 'active',
      size: MkSize.fromJson(raw['size']),
      couponCode: (raw['couponCode']?.toString() ?? '').isEmpty ? null : raw['couponCode'].toString(),
      layerCount: raw['layerCount'] is num ? (raw['layerCount'] as num).toInt() : 0,
      updatedAt: raw['updatedAt'] is num ? (raw['updatedAt'] as num).toInt() : null,
      updatedBy: raw['updatedBy']?.toString(),
    );
  }
}

/// 3.55 Marketing studio calls (all admin only; 403 FEATURE_OFF while the switch is off).
class MarketingApi {
  final ApiClient api;
  MarketingApi(this.api);

  static const String _base = '/admin/marketing';

  static MarketingTemplate _template(Object? res) {
    final t = res is Map ? res['template'] : null;
    if (t is! Map) throw const ApiException(0, 'The server sent no template.');
    return MarketingTemplate.fromJson(t);
  }

  Future<List<MkTemplateSummary>> list({String status = 'all'}) async {
    final res = await api.get('$_base/templates?status=$status', timeout: const Duration(seconds: 15));
    final list = res is Map && res['templates'] is List ? res['templates'] as List : const [];
    return list.map(MkTemplateSummary.fromJson).whereType<MkTemplateSummary>().toList();
  }

  Future<MarketingTemplate> get(String id) async => _template(await api.get('$_base/templates/${Uri.encodeComponent(id)}', timeout: const Duration(seconds: 15)));

  /// Creates [t] (no id) or replaces it (with id; conflict-checked against [MarketingTemplate.updatedAt]).
  Future<MarketingTemplate> save(MarketingTemplate t) async {
    if (t.id == null) return _template(await api.post('$_base/templates', t.toJson()));
    return _template(await api.put('$_base/templates/${Uri.encodeComponent(t.id!)}', {...t.toJson(), 'baseUpdatedAt': ?t.updatedAt}));
  }

  Future<MarketingTemplate> duplicate(String id) async => _template(await api.post('$_base/templates/${Uri.encodeComponent(id)}/duplicate', const <String, dynamic>{}));

  Future<MarketingTemplate> setStatus(String id, String status) async => _template(await api.patch('$_base/templates/${Uri.encodeComponent(id)}/status', {'status': status}));

  Future<void> delete(String id) async => api.delete('$_base/templates/${Uri.encodeComponent(id)}');

  /// Coupons a template can be bound to (active / scheduled; public fields only).
  Future<List<MkCouponInfo>> coupons() async {
    final res = await api.get('$_base/coupons', timeout: const Duration(seconds: 15));
    final list = res is Map && res['coupons'] is List ? res['coupons'] as List : const [];
    return list.map(MkCouponInfo.fromJson).whereType<MkCouponInfo>().toList();
  }

  /// Uploads image bytes (JPEG / PNG / WebP, at most 2 MB); returns the image id.
  Future<String> uploadImage(Uint8List bytes, String contentType) async {
    final res = await api.postBytes('$_base/images', bytes, contentType);
    final id = res is Map && res['image'] is Map ? (res['image'] as Map)['id']?.toString() : null;
    if (id == null || id.isEmpty) throw const ApiException(0, 'The image was not stored.');
    return id;
  }

  /// Downloads and decodes an uploaded image, or null when it cannot be read.
  Future<ui.Image?> loadImage(String id, {http.Client? client}) async {
    final c = client ?? http.Client();
    try {
      final res = await c.get(Uri.parse(api.apiUrlOf('$_base/images/${Uri.encodeComponent(id)}')), headers: api.authHeaders).timeout(const Duration(seconds: 30));
      if (res.statusCode != 200 || res.bodyBytes.isEmpty) return null;
      final codec = await ui.instantiateImageCodec(res.bodyBytes);
      final frame = await codec.getNextFrame();
      codec.dispose();
      return frame.image;
    } catch (_) {
      return null;
    } finally {
      if (client == null) c.close();
    }
  }

  /// Content type from the first bytes (null: not an accepted image).
  static String? sniffType(Uint8List b) {
    if (b.length < 12) return null;
    if (b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return 'image/jpeg';
    if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) return 'image/png';
    if (b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 && b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50) return 'image/webp';
    return null;
  }
}
