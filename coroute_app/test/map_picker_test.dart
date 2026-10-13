import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:coroute_app/core/theme/app_palette.dart';
import 'package:coroute_app/core/theme/app_theme.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/geo_service.dart';
import 'package:coroute_app/presentation/map_picker/map_picker_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ApiClient apiClient;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    apiClient = ApiClient(
      httpClient: MockClient((_) async => http.Response('{"features":[]}', 200)),
      storage: const FlutterSecureStorage(),
    );
    AppTheme.use(AppPalette.dark);
  });

  Widget buildScreen({PickedPlace? initial}) {
    return ChangeNotifierProvider<ApiClient>.value(
      value: apiClient,
      child: MaterialApp(
        theme: AppTheme.themeFor(AppPalette.dark),
        home: MapPickerScreen(
          title: 'Choose start',
          initial: initial ?? const PickedPlace(lat: 17.3850, lng: 78.4867, name: 'Hyderabad'),
        ),
      ),
    );
  }

  group('MapPickerScreen Coordinate and Search Tests', () {
    testWidgets('renders search field with paste coordinates button', (tester) async {
      await tester.pumpWidget(buildScreen());
      await tester.pump();

      expect(find.byType(TextField), findsNWidgets(2)); // Search and Name field
      expect(find.byIcon(Icons.content_paste_rounded), findsOneWidget);
      expect(find.byTooltip('Paste coordinates or text'), findsOneWidget);
    });

    testWidgets('typing decimal coordinates instantly shows Jump to coordinates row', (tester) async {
      await tester.pumpWidget(buildScreen());
      await tester.pump();

      final searchFinder = find.widgetWithText(TextField, 'Search place, town or coordinates');
      expect(searchFinder, findsOneWidget);

      await tester.enterText(searchFinder, '13.0827, 80.2707');
      await tester.pump();

      expect(find.text('Jump to coordinates'), findsOneWidget);
      expect(find.textContaining('13.082700, 80.270700'), findsOneWidget);

      // Tapping Jump to coordinates selects it
      await tester.tap(find.text('Jump to coordinates'));
      await tester.pump();

      // Jump to coordinates row should dismiss upon selection
      expect(find.text('Jump to coordinates'), findsNothing);
    });

    testWidgets('typing DMS coordinates shows Jump to coordinates row', (tester) async {
      await tester.pumpWidget(buildScreen());
      await tester.pump();

      final searchFinder = find.widgetWithText(TextField, 'Search place, town or coordinates');
      await tester.enterText(searchFinder, '17°23\'06.2"N 78°29\'12.0"E');
      await tester.pump();

      expect(find.text('Jump to coordinates'), findsOneWidget);
      expect(find.textContaining('17.385056'), findsOneWidget);
    });

    testWidgets('shows empty state message when search returns no matches', (tester) async {
      await tester.pumpWidget(buildScreen());
      await tester.pump();

      final searchFinder = find.widgetWithText(TextField, 'Search place, town or coordinates');
      await tester.enterText(searchFinder, 'Unicorn Station Nowhere');
      // Wait for debounce timer (600ms)
      await tester.pump(const Duration(milliseconds: 700));

      expect(find.textContaining('No matching places found'), findsOneWidget);
    });

    testWidgets('paste button reads coordinates from clipboard and pins location', (tester) async {
      // Mock clipboard getData
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (MethodCall methodCall) async {
          if (methodCall.method == 'Clipboard.getData') {
            return {'text': '15.3173, 75.7139'};
          }
          return null;
        },
      );

      await tester.pumpWidget(buildScreen());
      await tester.pump();

      await tester.tap(find.byTooltip('Paste coordinates or text'));
      await tester.pump();

      // Search text is populated with coordinates
      expect(find.textContaining('15.317300, 75.713900'), findsWidgets);
    });
  });
}
