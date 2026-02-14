import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:timer_desktop/main.dart';

/// アプリの起動確認だけを行う最小テストです。
void main() {
  /// ルートウィジェットが描画できることを確認するテストです。
  testWidgets('TimerDesktopApp を描画できる', (WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => AppState(),
        child: const TimerDesktopApp(),
      ),
    );
    expect(find.byType(TimerHomePage), findsOneWidget);
  });
}
