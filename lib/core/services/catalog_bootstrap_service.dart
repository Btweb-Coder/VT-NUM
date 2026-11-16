import '../../features/activate/data/tnum_repository.dart';
import 'catalog_repository.dart';

class CatalogLoad<T> {
  const CatalogLoad({required this.data, this.error});
  final T data;
  final Object? error;
}

class TnumCatalogSnapshot {
  const TnumCatalogSnapshot({
    required this.countries,
    required this.catalog,
    this.error,
  });
  final List<Map<String, dynamic>> countries;
  final List<Map<String, dynamic>> catalog;
  final Object? error;

  factory TnumCatalogSnapshot.fromMap(Map<String, dynamic> value) =>
      TnumCatalogSnapshot(
        countries: (value['countries'] as List? ?? [])
            .map((row) => Map<String, dynamic>.from(row as Map))
            .toList(),
        catalog: (value['catalog'] as List? ?? [])
            .map((row) => Map<String, dynamic>.from(row as Map))
            .toList(),
      );
}

/// Starts the independent catalog loads once for the authenticated app session.
class CatalogBootstrapService {
  static final CatalogBootstrapService instance = CatalogBootstrapService._();
  CatalogBootstrapService._();

  Future<CatalogLoad<List<CatalogItem>>>? _vtServices;
  Future<CatalogLoad<List<CatalogItem>>>? _vtCountries;
  Future<CatalogLoad<TnumCatalogSnapshot>>? _tnum;

  void start() {
    _vtServices ??= _loadVt('services');
    _vtCountries ??= _loadVt('countries');
    _tnum ??= _loadTnum();
  }

  Future<CatalogLoad<List<CatalogItem>>> get vtServices {
    start();
    return _vtServices!;
  }

  Future<CatalogLoad<List<CatalogItem>>> get vtCountries {
    start();
    return _vtCountries!;
  }

  Future<CatalogLoad<TnumCatalogSnapshot>> get tnumCatalog {
    start();
    return _tnum!;
  }

  Future<CatalogLoad<List<CatalogItem>>> _loadVt(String type) async {
    try {
      return CatalogLoad(data: await CatalogRepository().load(type));
    } catch (error) {
      return CatalogLoad(data: const [], error: error);
    }
  }

  Future<CatalogLoad<TnumCatalogSnapshot>> _loadTnum() async {
    try {
      final repository = TnumRepository();
      var data = await repository.loadCatalog();
      final countries = (data['countries'] as List? ?? [])
          .map((row) => Map<String, dynamic>.from(row as Map))
          .toList();
      final firstCode = countries.isEmpty
          ? null
          : int.tryParse('${countries.first['code']}');
      if (firstCode != null) {
        try {
          data = await repository.refreshCountry(firstCode);
        } catch (_) {
          // The cached response remains usable when OnlineSIM is unavailable.
        }
      }
      return CatalogLoad(data: TnumCatalogSnapshot.fromMap(data));
    } catch (error) {
      return CatalogLoad(
        data: const TnumCatalogSnapshot(countries: [], catalog: []),
        error: error,
      );
    }
  }

  Future<CatalogLoad<TnumCatalogSnapshot>> refreshTnumCountry(int code) async {
    try {
      final data = await TnumRepository().refreshCountry(code);
      final snapshot = TnumCatalogSnapshot.fromMap(data);
      _tnum = Future.value(CatalogLoad(data: snapshot));
      return CatalogLoad(data: snapshot);
    } catch (error) {
      return CatalogLoad(
        data: (await tnumCatalog).data,
        error: error,
      );
    }
  }

  void resetForSignOut() {
    _vtServices = null;
    _vtCountries = null;
    _tnum = null;
  }
}
