import 'package:supabase_flutter/supabase_flutter.dart';

class CatalogItem {
  const CatalogItem({required this.id, required this.name, this.flag = ''});
  final String id;
  final String name;
  final String flag;
}

class CatalogRepository {
  CatalogRepository({SupabaseClient? client}) : _client = client ?? Supabase.instance.client;
  final SupabaseClient _client;

  Future<List<CatalogItem>> load(String type) async {
    final table = type == 'services' ? 'services' : type == 'countries' ? 'countries' : null;
    if (table == null) throw ArgumentError.value(type, 'type');
    final snapshot = await _client.from(table).select('id,name,flag').eq('active', true).order('name');
    final values = (snapshot as List).cast<Map<String, dynamic>>().map((data) => CatalogItem(id: data['id'] as String, name: data['name'] as String, flag: data['flag'] as String? ?? '')).toList();
    values.sort((a, b) => a.name.compareTo(b.name));
    return values;
  }
}
