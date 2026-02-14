import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

/// アプリ起動時の初期化を行い、Provider を登録して画面を表示する関数です。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isMacOS) {
    await windowManager.ensureInitialized();
  }
  runApp(
    ChangeNotifierProvider(
      create: (_) => AppState()..initialize(),
      child: const TimerDesktopApp(),
    ),
  );
}

/// ルートウィジェットです。
class TimerDesktopApp extends StatelessWidget {
  const TimerDesktopApp({super.key});

  /// MaterialApp の基本設定を返す関数です。
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Timer Desktop',
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.cyan,
        scaffoldBackgroundColor: Colors.black,
      ),
      home: const TimerHomePage(),
    );
  }
}

/// 通知ルールの種別です。
enum RuleType { main, sub }

/// 通知ルールの基準時刻です。
enum RuleBase { start, end }

/// 通知ルールを表すモデルです。
class NotificationRule {
  NotificationRule({
    required this.type,
    required this.base,
    required this.beforeMinutes,
  });

  final RuleType type;
  final RuleBase base;
  final int? beforeMinutes;

  /// 表示用の通知種別ラベルを返す関数です。
  String get typeLabel => type == RuleType.main ? 'メイン' : 'サブ';

  /// 表示用の基準ラベルを返す関数です。
  String get baseLabel => base == RuleBase.start ? '開始' : '終了';

  /// JSON 保存用の Map に変換する関数です。
  Map<String, dynamic> toMap() {
    return {
      'type': type.name,
      'base': base.name,
      'beforeMinutes': beforeMinutes,
    };
  }

  /// Map から NotificationRule を復元する関数です。
  static NotificationRule fromMap(Map<String, dynamic> map) {
    return NotificationRule(
      type: map['type'] == 'sub' ? RuleType.sub : RuleType.main,
      base: map['base'] == 'end' ? RuleBase.end : RuleBase.start,
      beforeMinutes: map['beforeMinutes'] as int?,
    );
  }
}

/// 表示キュー用メッセージモデルです。
class DisplayMessage {
  DisplayMessage({
    required this.id,
    required this.text,
    required this.createdAt,
    required this.isSub,
    this.linkedAlarmId,
    this.isBlinking = false,
  });

  final String id;
  final String text;
  final DateTime createdAt;
  final bool isSub;
  final String? linkedAlarmId;
  final bool isBlinking;
}

/// 音声キュー用メッセージモデルです。
class VoiceMessage {
  VoiceMessage({
    required this.id,
    required this.fullText,
    required this.speakText,
    required this.createdAt,
  });

  final String id;
  final String fullText;
  final String speakText;
  final DateTime createdAt;
}

/// カスタムタイマーを表すモデルです。
class CustomTimerItem {
  CustomTimerItem({
    required this.id,
    required this.title,
    required this.endAt,
  });

  final String id;
  final String title;
  final DateTime endAt;
  bool finished = false;

  /// 現在時刻から見た残り時間を返す関数です。
  Duration remaining(DateTime now) {
    final diff = endAt.difference(now);
    if (diff.isNegative) {
      return Duration.zero;
    }
    return diff;
  }
}

/// アプリ内ログを表すモデルです。
class LogEntry {
  LogEntry({required this.time, required this.message});

  final DateTime time;
  final String message;
}

/// 通知候補イベントを表すモデルです。
class EventPlan {
  EventPlan({
    required this.id,
    required this.title,
    required this.time,
    required this.ruleType,
  });

  final String id;
  final String title;
  final DateTime time;
  final RuleType ruleType;
}

/// Provider の中核として、設定・タイマー・通知キューの状態を管理するクラスです。
class AppState extends ChangeNotifier {
  static const String _keyVoiceMaxChars = 'voiceMaxChars';
  static const String _keyVoiceQueueMax = 'voiceQueueMax';
  static const String _keyDisplayQueueMax = 'displayQueueMax';
  static const String _keyFadeSeconds = 'fadeSeconds';
  static const String _keyTimeRangeText = 'timeRangeText';
  static const String _keySubTimeRangeText = 'subTimeRangeText';
  static const String _keyRulesJson = 'rulesJson';

  final FlutterTts _tts = FlutterTts();

  Timer? _secondTicker;
  Timer? _fadeTicker;
  Timer? _alarmTicker;

  DateTime _lastPointerTime = DateTime.now();
  final Set<String> _firedEventIds = <String>{};
  bool _isSpeaking = false;
  bool _suspendFade = false;

  bool initialized = false;
  DateTime now = DateTime.now();

  int voiceMaxChars = 100;
  int voiceQueueMax = 10;
  int displayQueueMax = 10;
  int fadeSeconds = 5;
  String timeRangeText = '09:00 - 10:00';
  String subTimeRangeText = '09:00 - 10:00';

  bool isFaded = false;
  bool isMute = false;

  String centerTitle = 'イベント未設定';
  Duration centerRemaining = Duration.zero;
  double centerProgress = 0;
  String mainNotification = '';

  final List<NotificationRule> notificationRules = <NotificationRule>[
    NotificationRule(type: RuleType.main, base: RuleBase.start, beforeMinutes: 5),
    NotificationRule(type: RuleType.sub, base: RuleBase.start, beforeMinutes: 0),
    NotificationRule(type: RuleType.sub, base: RuleBase.end, beforeMinutes: 5),
    NotificationRule(type: RuleType.main, base: RuleBase.end, beforeMinutes: null),
  ];

  final List<DisplayMessage> displayQueue = <DisplayMessage>[];
  final List<VoiceMessage> voiceQueue = <VoiceMessage>[];
  final List<CustomTimerItem> customTimers = <CustomTimerItem>[];
  final List<LogEntry> logs = <LogEntry>[];
  final List<String> alarmQueueIds = <String>[];

  /// Provider 初期化時に各種設定とタイマーを開始する関数です。
  Future<void> initialize() async {
    await _configureTts();
    await _loadSettings();
    _startPeriodicTimers();
    initialized = true;
    notifyListeners();
  }

  /// Provider 破棄時に全タイマーと音声を停止する関数です。
  @override
  void dispose() {
    _secondTicker?.cancel();
    _fadeTicker?.cancel();
    _alarmTicker?.cancel();
    _tts.stop();
    displayQueue.clear();
    voiceQueue.clear();
    logs.clear();
    super.dispose();
  }

  /// flutter_tts の基本設定を行う関数です。
  Future<void> _configureTts() async {
    await _tts.setLanguage('ja-JP');
    await _tts.setSpeechRate(0.5);
    await _tts.setPitch(1.0);
    await _tts.awaitSpeakCompletion(true);
  }

  /// shared_preferences から保存済み設定を読み込む関数です。
  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    voiceMaxChars = prefs.getInt(_keyVoiceMaxChars) ?? 100;
    voiceQueueMax = prefs.getInt(_keyVoiceQueueMax) ?? 10;
    displayQueueMax = prefs.getInt(_keyDisplayQueueMax) ?? 10;
    fadeSeconds = prefs.getInt(_keyFadeSeconds) ?? 5;
    timeRangeText = prefs.getString(_keyTimeRangeText) ?? '09:00 - 10:00';
    subTimeRangeText = prefs.getString(_keySubTimeRangeText) ?? timeRangeText;

    final rulesJson = prefs.getString(_keyRulesJson);
    if (rulesJson != null && rulesJson.isNotEmpty) {
      final decoded = jsonDecode(rulesJson) as List<dynamic>;
      notificationRules
        ..clear()
        ..addAll(
          decoded
              .map((e) => NotificationRule.fromMap(e as Map<String, dynamic>))
              .toList(),
        );
    }
  }

  /// 現在の設定を shared_preferences に保存する関数です。
  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyVoiceMaxChars, voiceMaxChars);
    await prefs.setInt(_keyVoiceQueueMax, voiceQueueMax);
    await prefs.setInt(_keyDisplayQueueMax, displayQueueMax);
    await prefs.setInt(_keyFadeSeconds, fadeSeconds);
    await prefs.setString(_keyTimeRangeText, timeRangeText);
    await prefs.setString(_keySubTimeRangeText, subTimeRangeText);
    await prefs.setString(
      _keyRulesJson,
      jsonEncode(notificationRules.map((e) => e.toMap()).toList()),
    );
  }

  /// 1秒タイマーとフェード監視タイマーを開始する関数です。
  void _startPeriodicTimers() {
    _secondTicker?.cancel();
    _fadeTicker?.cancel();

    _secondTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      _onSecondTick();
    });

    _fadeTicker = Timer.periodic(const Duration(milliseconds: 200), (_) {
      _updateFadeByIdleTime();
    });
  }

  /// マウス操作があったことを記録し、フェードを解除する関数です。
  void onPointerActivity() {
    _lastPointerTime = DateTime.now();
    if (isFaded) {
      _setFaded(false);
    }
  }

  /// 1秒ごとに全体状態を更新する関数です。
  void _onSecondTick() {
    now = DateTime.now();
    _removeOldLogs();
    _fireDueRuleEvents();
    _updateCenterEvent();
    _updateCustomTimers();
    _sortCustomTimers();
    notifyListeners();
  }

  /// 無操作時間を監視してフェード状態を切り替える関数です。
  void _updateFadeByIdleTime() {
    if (_suspendFade) {
      return;
    }
    final idleSeconds = DateTime.now().difference(_lastPointerTime).inSeconds;
    final shouldFade = idleSeconds >= fadeSeconds;
    if (shouldFade != isFaded) {
      _setFaded(shouldFade);
    }
  }

  /// フェード状態を反映し、macOS ではクリック透過も切り替える関数です。
  Future<void> _setFaded(bool value) async {
    isFaded = value;
    if (Platform.isMacOS) {
      await windowManager.setIgnoreMouseEvents(value, forward: true);
    }
    notifyListeners();
  }

  /// 設定値をまとめて更新し、保存する関数です。
  Future<void> applySettings({
    required int newVoiceMaxChars,
    required int newVoiceQueueMax,
    required int newDisplayQueueMax,
    required int newFadeSeconds,
    required String newTimeRangeText,
    required String newSubTimeRangeText,
    required List<NotificationRule> newRules,
  }) async {
    voiceMaxChars = math.max(1, newVoiceMaxChars);
    voiceQueueMax = math.max(1, newVoiceQueueMax);
    displayQueueMax = math.max(1, newDisplayQueueMax);
    fadeSeconds = math.max(1, newFadeSeconds);
    timeRangeText = newTimeRangeText;
    subTimeRangeText = newSubTimeRangeText;
    notificationRules
      ..clear()
      ..addAll(newRules);

    _firedEventIds.clear();
    await _saveSettings();
    notifyListeners();
  }

  /// 設定ダイアログ表示中はフェードを停止し、確実に操作可能にする関数です。
  Future<void> beginModalInteraction() async {
    _suspendFade = true;
    onPointerActivity();
    if (isFaded) {
      await _setFaded(false);
    }
  }

  /// 設定ダイアログ終了後にフェード監視を再開する関数です。
  void endModalInteraction() {
    _suspendFade = false;
    onPointerActivity();
  }

  /// サブ通知表示用の文字列を作成する関数です。
  String get subNotificationText {
    final subTexts = displayQueue.where((e) => e.isSub).map((e) => e.text).toList();
    if (subTexts.isEmpty) {
      return '';
    }
    return subTexts.join('   |   ');
  }

  /// カスタムタイマーを追加する関数です。
  void addCustomTimer({required String title, required Duration duration}) {
    if (duration.inSeconds <= 0) {
      return;
    }
    final id = 'ct-${DateTime.now().microsecondsSinceEpoch}';
    customTimers.add(
      CustomTimerItem(
        id: id,
        title: title.trim().isEmpty ? 'カスタムタイマー' : title.trim(),
        endAt: DateTime.now().add(duration),
      ),
    );
    _sortCustomTimers();
    notifyListeners();
  }

  /// カスタムタイマーを手動停止して完全削除する関数です。
  void stopAndRemoveCustomTimer(String timerId) {
    customTimers.removeWhere((e) => e.id == timerId);
    removeAlarm(timerId);
    displayQueue.removeWhere((e) => e.linkedAlarmId == timerId);
    notifyListeners();
  }

  /// 表示キューのメッセージを個別削除する関数です。
  void removeDisplayMessage(String messageId) {
    displayQueue.removeWhere((e) => e.id == messageId);
    notifyListeners();
  }

  /// 音声キューを一時停止し、現在再生と待機キューを停止する関数です。
  Future<void> pauseVoiceAndClearQueue() async {
    voiceQueue.clear();
    _isSpeaking = false;
    await _tts.stop();
    _addLog('音声キューを一時停止しました。');
    notifyListeners();
  }

  /// ミュート状態を切り替える関数です。
  void toggleMute() {
    isMute = !isMute;
    _addLog(isMute ? 'ミュートを有効にしました。' : 'ミュートを解除しました。');
    notifyListeners();
  }

  /// 表示キューへメッセージを追加する関数です。
  void _enqueueDisplay({
    required String text,
    required bool isSub,
    String? linkedAlarmId,
    bool isBlinking = false,
  }) {
    if (displayQueue.length >= displayQueueMax) {
      _addLog('表示キュー満杯のため追加を拒否: $text');
      return;
    }
    displayQueue.add(
      DisplayMessage(
        id: 'd-${DateTime.now().microsecondsSinceEpoch}',
        text: text,
        createdAt: DateTime.now(),
        isSub: isSub,
        linkedAlarmId: linkedAlarmId,
        isBlinking: isBlinking,
      ),
    );
    _addLog('表示通知追加: $text');
  }

  /// 音声キューへメッセージを追加する関数です。
  void _enqueueVoice(String text) {
    if (isMute) {
      _addLog('ミュート中のため音声通知をスキップ: $text');
      return;
    }
    if (voiceQueue.length >= voiceQueueMax) {
      _addLog('音声キュー満杯のため追加を拒否: $text');
      return;
    }

    final trimmed = text.length > voiceMaxChars
        ? '${text.substring(0, voiceMaxChars)}...'
        : text;

    voiceQueue.add(
      VoiceMessage(
        id: 'v-${DateTime.now().microsecondsSinceEpoch}',
        fullText: text,
        speakText: trimmed,
        createdAt: DateTime.now(),
      ),
    );
    _addLog('音声通知追加: $text');
    _processVoiceQueue();
  }

  /// 音声キューを FIFO で1件ずつ再生する関数です。
  Future<void> _processVoiceQueue() async {
    if (_isSpeaking || voiceQueue.isEmpty) {
      return;
    }
    if (isMute) {
      voiceQueue.clear();
      _isSpeaking = false;
      notifyListeners();
      return;
    }

    _isSpeaking = true;
    final next = voiceQueue.removeAt(0);
    try {
      await _tts.speak(next.speakText);
      _addLog('音声再生完了: ${next.fullText}');
    } catch (_) {
      _addLog('音声再生失敗: ${next.fullText}');
    }
    _isSpeaking = false;
    notifyListeners();

    if (voiceQueue.isNotEmpty) {
      _processVoiceQueue();
    }
  }

  /// アラームキューへ追加し、必要なら鳴動ループを開始する関数です。
  void _enqueueAlarm(String alarmId) {
    if (alarmQueueIds.contains(alarmId)) {
      return;
    }
    alarmQueueIds.add(alarmId);
    _startAlarmLoopIfNeeded();
    notifyListeners();
  }

  /// アラームIDをキューから削除し、空なら鳴動を停止する関数です。
  void removeAlarm(String alarmId) {
    alarmQueueIds.remove(alarmId);
    if (alarmQueueIds.isEmpty) {
      _alarmTicker?.cancel();
      _alarmTicker = null;
    }
    notifyListeners();
  }

  /// アラームキューがある間だけ電子音を鳴らすループを開始する関数です。
  void _startAlarmLoopIfNeeded() {
    if (_alarmTicker != null) {
      return;
    }
    _alarmTicker = Timer.periodic(const Duration(milliseconds: 900), (_) {
      if (alarmQueueIds.isEmpty) {
        _alarmTicker?.cancel();
        _alarmTicker = null;
        return;
      }
      SystemSound.play(SystemSoundType.alert);
    });
  }

  /// ログを追加する関数です。
  void _addLog(String message) {
    logs.add(LogEntry(time: DateTime.now(), message: message));
  }

  /// 24時間を超えたログを削除する関数です。
  void _removeOldLogs() {
    final limit = DateTime.now().subtract(const Duration(hours: 24));
    logs.removeWhere((e) => e.time.isBefore(limit));
  }

  /// カスタムタイマーの残り時間が短い順に並び替える関数です。
  void _sortCustomTimers() {
    customTimers.sort((a, b) {
      return a.remaining(now).compareTo(b.remaining(now));
    });
  }

  /// カスタムタイマーの完了判定と通知追加を行う関数です。
  void _updateCustomTimers() {
    for (final timer in customTimers) {
      if (timer.finished) {
        continue;
      }
      if (now.isBefore(timer.endAt)) {
        continue;
      }

      timer.finished = true;
      _enqueueDisplay(
        text: 'カスタムタイマー終了: ${timer.title}',
        isSub: false,
        linkedAlarmId: timer.id,
        isBlinking: true,
      );
      _enqueueAlarm(timer.id);
      _addLog('カスタムタイマー終了: ${timer.title}');
    }
  }

  /// 通知ルールに従って、現在有効なイベント一覧を作る関数です。
  List<EventPlan> _buildCurrentEventPlans() {
    final mainRange = _parseTimeRange(timeRangeText, now);
    if (mainRange == null) {
      return <EventPlan>[];
    }
    final subRange = _parseTimeRange(subTimeRangeText, now) ?? mainRange;

    final List<EventPlan> plans = <EventPlan>[];
    for (final rule in notificationRules) {
      if (rule.beforeMinutes == null) {
        continue;
      }

      final activeRange = rule.type == RuleType.sub ? subRange : mainRange;
      final DateTime start = activeRange.$1;
      final DateTime end = activeRange.$2;
      final baseTime = rule.base == RuleBase.start ? start : end;
      final eventTime = baseTime.subtract(Duration(minutes: rule.beforeMinutes!));
      final title = '${rule.typeLabel}${rule.baseLabel}';
      plans.add(
        EventPlan(
          id: '${title}_${eventTime.millisecondsSinceEpoch}',
          title: title,
          time: eventTime,
          ruleType: rule.type,
        ),
      );
    }

    plans.sort((a, b) => a.time.compareTo(b.time));
    return plans;
  }

  /// ルールイベントが発火時刻を過ぎていたらキューへ投入する関数です。
  void _fireDueRuleEvents() {
    final plans = _buildCurrentEventPlans();
    for (final plan in plans) {
      if (_firedEventIds.contains(plan.id)) {
        continue;
      }
      if (now.isBefore(plan.time)) {
        continue;
      }

      _firedEventIds.add(plan.id);
      final text = '${plan.title} の時刻です';
      _enqueueDisplay(text: text, isSub: plan.ruleType == RuleType.sub);
      _enqueueVoice(text);
      mainNotification = text;
      _addLog('ルール通知発火: $text');
    }
  }

  /// 中央表示する最短未来イベントと残り時間を更新する関数です。
  void _updateCenterEvent() {
    final plans = _buildCurrentEventPlans();
    final futures = plans.where((e) => e.time.isAfter(now)).toList();
    if (futures.isEmpty) {
      centerTitle = '次のイベントなし';
      centerRemaining = Duration.zero;
      centerProgress = 0;
      return;
    }

    final next = futures.first;
    centerTitle = next.title;
    centerRemaining = next.time.difference(now);

    final mainRange = _parseTimeRange(timeRangeText, now);
    final subRange = _parseTimeRange(subTimeRangeText, now) ?? mainRange;
    if (mainRange == null) {
      centerProgress = 0;
      return;
    }

    final nextIndex = plans.indexWhere((e) => e.id == next.id);
    DateTime progressStart;
    if (nextIndex > 0) {
      progressStart = plans[nextIndex - 1].time;
    } else {
      final baseRange = next.ruleType == RuleType.sub ? subRange : mainRange;
      progressStart = baseRange!.$1;
    }

    final total = next.time.difference(progressStart).inSeconds;
    final passed = now.difference(progressStart).inSeconds;
    if (total <= 0) {
      centerProgress = 0;
      return;
    }
    centerProgress = (passed / total).clamp(0, 1);
  }

  /// `HH:MM - HH:MM` 形式を当日の DateTime 範囲へ変換する関数です。
  (DateTime, DateTime)? _parseTimeRange(String input, DateTime baseDay) {
    final reg = RegExp(r'^\s*(\d{1,2}):(\d{2})\s*-\s*(\d{1,2}):(\d{2})\s*$');
    final match = reg.firstMatch(input);
    if (match == null) {
      return null;
    }

    final sh = int.parse(match.group(1)!);
    final sm = int.parse(match.group(2)!);
    final eh = int.parse(match.group(3)!);
    final em = int.parse(match.group(4)!);

    if (sh > 23 || eh > 23 || sm > 59 || em > 59) {
      return null;
    }

    DateTime start = DateTime(baseDay.year, baseDay.month, baseDay.day, sh, sm);
    DateTime end = DateTime(baseDay.year, baseDay.month, baseDay.day, eh, em);
    if (!end.isAfter(start)) {
      end = end.add(const Duration(days: 1));
    }

    if (DateTime.now().isAfter(end)) {
      start = start.add(const Duration(days: 1));
      end = end.add(const Duration(days: 1));
      _firedEventIds.clear();
    }

    return (start, end);
  }
}

/// ホーム画面全体を表示するウィジェットです。
class TimerHomePage extends StatefulWidget {
  const TimerHomePage({super.key});

  /// State を生成する関数です。
  @override
  State<TimerHomePage> createState() => _TimerHomePageState();
}

/// ホーム画面の状態管理クラスです。
class _TimerHomePageState extends State<TimerHomePage> {
  /// 設定ダイアログを表示する関数です。
  Future<void> _openSettingsDialog(AppState app) async {
    await app.beginModalInteraction();
    if (!mounted) {
      app.endModalInteraction();
      return;
    }
    final voiceController = TextEditingController(text: app.voiceMaxChars.toString());
    final voiceQueueController = TextEditingController(text: app.voiceQueueMax.toString());
    final displayQueueController = TextEditingController(text: app.displayQueueMax.toString());
    final fadeController = TextEditingController(text: app.fadeSeconds.toString());
    final rangeController = TextEditingController(text: app.timeRangeText);
    final subRangeController = TextEditingController(text: app.subTimeRangeText);

    final localRules = app.notificationRules
        .map(
          (e) => NotificationRule(
            type: e.type,
            base: e.base,
            beforeMinutes: e.beforeMinutes,
          ),
        )
        .toList();

    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) {
          return AlertDialog(
            title: const Text('設定'),
            content: SizedBox(
              width: 560,
              child: StatefulBuilder(
                builder: (context, setLocalState) {
                  return SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _numberField('音声最大文字数', voiceController),
                        _numberField('音声キュー最大数', voiceQueueController),
                        _numberField('表示キュー最大数', displayQueueController),
                        _numberField('フェード秒数', fadeController),
                        const SizedBox(height: 12),
                        TextField(
                          controller: rangeController,
                          decoration: const InputDecoration(
                            labelText: 'メイン時刻範囲 (HH:MM - HH:MM)',
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: subRangeController,
                          decoration: const InputDecoration(
                            labelText: 'サブ時刻範囲 (HH:MM - HH:MM)',
                          ),
                        ),
                        const SizedBox(height: 16),
                        const Text('通知ルール編集'),
                        const SizedBox(height: 8),
                        ...localRules.asMap().entries.map((entry) {
                          final i = entry.key;
                          final rule = entry.value;
                          return Row(
                            children: [
                              DropdownButton<RuleType>(
                                value: rule.type,
                                onChanged: (v) {
                                  if (v == null) {
                                    return;
                                  }
                                  setLocalState(() {
                                    localRules[i] = NotificationRule(
                                      type: v,
                                      base: rule.base,
                                      beforeMinutes: rule.beforeMinutes,
                                    );
                                  });
                                },
                                items: const [
                                  DropdownMenuItem(value: RuleType.main, child: Text('メイン')),
                                  DropdownMenuItem(value: RuleType.sub, child: Text('サブ')),
                                ],
                              ),
                              const SizedBox(width: 8),
                              DropdownButton<RuleBase>(
                                value: rule.base,
                                onChanged: (v) {
                                  if (v == null) {
                                    return;
                                  }
                                  setLocalState(() {
                                    localRules[i] = NotificationRule(
                                      type: rule.type,
                                      base: v,
                                      beforeMinutes: rule.beforeMinutes,
                                    );
                                  });
                                },
                                items: const [
                                  DropdownMenuItem(value: RuleBase.start, child: Text('開始')),
                                  DropdownMenuItem(value: RuleBase.end, child: Text('終了')),
                                ],
                              ),
                              const SizedBox(width: 8),
                              SizedBox(
                                width: 110,
                                child: TextFormField(
                                  initialValue: rule.beforeMinutes?.toString() ?? '',
                                  decoration: const InputDecoration(labelText: '分前(null可)'),
                                  keyboardType: TextInputType.number,
                                  onChanged: (v) {
                                    setLocalState(() {
                                      localRules[i] = NotificationRule(
                                        type: rule.type,
                                        base: rule.base,
                                        beforeMinutes: int.tryParse(v),
                                      );
                                    });
                                  },
                                ),
                              ),
                            ],
                          );
                        }),
                      ],
                    ),
                  );
                },
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('キャンセル'),
              ),
              FilledButton(
                onPressed: () async {
                  await app.applySettings(
                    newVoiceMaxChars: int.tryParse(voiceController.text) ?? app.voiceMaxChars,
                    newVoiceQueueMax: int.tryParse(voiceQueueController.text) ?? app.voiceQueueMax,
                    newDisplayQueueMax:
                        int.tryParse(displayQueueController.text) ?? app.displayQueueMax,
                    newFadeSeconds: int.tryParse(fadeController.text) ?? app.fadeSeconds,
                    newTimeRangeText: rangeController.text,
                    newSubTimeRangeText: subRangeController.text,
                    newRules: localRules,
                  );
                  if (mounted) {
                    Navigator.of(context).pop();
                  }
                },
                child: const Text('保存'),
              ),
            ],
          );
        },
      );
    } finally {
      app.endModalInteraction();
    }
  }

  /// 数値入力用テキストフィールドを返す関数です。
  Widget _numberField(String label, TextEditingController controller) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        controller: controller,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(labelText: label),
      ),
    );
  }

  /// カスタムタイマー追加ダイアログを表示する関数です。
  Future<void> _openAddCustomTimerDialog(AppState app) async {
    await app.beginModalInteraction();
    if (!mounted) {
      app.endModalInteraction();
      return;
    }
    final titleController = TextEditingController();
    final minutesController = TextEditingController(text: '5');

    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) {
          return AlertDialog(
            title: const Text('カスタムタイマー追加'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: titleController,
                  decoration: const InputDecoration(labelText: 'タイトル'),
                ),
                TextField(
                  controller: minutesController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '分数'),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('閉じる'),
              ),
              FilledButton(
                onPressed: () {
                  final mins = int.tryParse(minutesController.text) ?? 0;
                  app.addCustomTimer(
                    title: titleController.text,
                    duration: Duration(minutes: mins),
                  );
                  Navigator.of(context).pop();
                },
                child: const Text('追加'),
              ),
            ],
          );
        },
      );
    } finally {
      app.endModalInteraction();
    }
  }

  /// タブバーを返す関数です。
  Widget _buildTabBar(bool faded) {
    if (faded) {
      return const SizedBox.shrink();
    }
    return const Row(
      children: [
        _TabButton(label: 'Timer', enabled: true),
        _TabButton(label: 'API', enabled: false),
        _TabButton(label: 'WebSocket', enabled: false),
        _TabButton(label: 'Extras', enabled: false),
      ],
    );
  }

  /// 時間を `HH:MM:SS` 表示へ整形する関数です。
  String _formatDuration(Duration duration) {
    final total = duration.inSeconds;
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  /// 画面全体を構築する関数です。
  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, app, _) {
        return Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) => app.onPointerActivity(),
          onPointerHover: (_) => app.onPointerActivity(),
          onPointerMove: (_) => app.onPointerActivity(),
          child: Scaffold(
            backgroundColor: app.isFaded ? Colors.transparent : const Color(0xFF111318),
            body: AnimatedOpacity(
              duration: const Duration(milliseconds: 200),
              opacity: app.isFaded ? 0.45 : 1,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildTabBar(app.isFaded),
                      if (!app.isFaded) const SizedBox(height: 10),
                      if (!app.isFaded)
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            FilledButton(
                              onPressed: () => _openSettingsDialog(app),
                              child: const Text('設定'),
                            ),
                            FilledButton(
                              onPressed: () => _openAddCustomTimerDialog(app),
                              child: const Text('カスタムタイマー追加'),
                            ),
                            FilledButton.tonal(
                              onPressed: () => app.pauseVoiceAndClearQueue(),
                              child: const Text('音声一時停止'),
                            ),
                            FilledButton.tonal(
                              onPressed: () => app.toggleMute(),
                              child: Text(app.isMute ? 'MUTE解除' : 'MUTE'),
                            ),
                          ],
                        ),
                      const SizedBox(height: 16),
                      Expanded(
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final size = math.min(constraints.maxWidth * 0.5, 320.0);
                            final strokeWidth = math.max(8.0, size * 0.08);

                            return Column(
                              children: [
                                Center(
                                  child: SizedBox(
                                    width: size,
                                    height: size,
                                    child: CustomPaint(
                                      painter: ProgressCirclePainter(
                                        progress: app.centerProgress,
                                        strokeWidth: strokeWidth,
                                      ),
                                      child: Padding(
                                        padding: const EdgeInsets.all(24),
                                        child: Column(
                                          mainAxisAlignment: MainAxisAlignment.center,
                                          children: [
                                            SizedBox(
                                              width: double.infinity,
                                              child: Text(
                                                app.centerTitle,
                                                maxLines: 1,
                                                softWrap: false,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(fontSize: 14, color: Colors.white70),
                                                textAlign: TextAlign.center,
                                              ),
                                            ),
                                            const SizedBox(height: 8),
                                            SizedBox(
                                              width: double.infinity,
                                              child: FittedBox(
                                                fit: BoxFit.scaleDown,
                                                child: Text(
                                                  _formatDuration(app.centerRemaining),
                                                  maxLines: 1,
                                                  softWrap: false,
                                                  style: const TextStyle(
                                                    fontSize: 34,
                                                    color: Colors.white,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                  textAlign: TextAlign.center,
                                                ),
                                              ),
                                            ),
                                            const SizedBox(height: 6),
                                            SizedBox(
                                              width: double.infinity,
                                              child: Text(
                                                app.mainNotification,
                                                maxLines: 1,
                                                softWrap: false,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(fontSize: 13, color: Colors.cyanAccent),
                                                textAlign: TextAlign.center,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 10),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(6),
                                  child: LinearProgressIndicator(
                                    minHeight: 10,
                                    value: app.centerProgress,
                                    backgroundColor: Colors.white24,
                                    valueColor: const AlwaysStoppedAnimation<Color>(Colors.cyanAccent),
                                  ),
                                ),
                                const SizedBox(height: 14),
                                if (app.subNotificationText.isNotEmpty)
                                  Container(
                                    height: 32,
                                    width: double.infinity,
                                    padding: const EdgeInsets.symmetric(horizontal: 8),
                                    decoration: BoxDecoration(
                                      border: Border.all(color: Colors.white24),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: MarqueeText(text: app.subNotificationText),
                                  ),
                                const SizedBox(height: 16),
                                const Divider(color: Colors.white24),
                                const SizedBox(height: 8),
                                const Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    'カスタムタイマー一覧',
                                    style: TextStyle(fontSize: 14, color: Colors.white70),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Expanded(
                                  child: ListView.builder(
                                    itemCount: app.customTimers.length,
                                    itemBuilder: (context, index) {
                                      final timer = app.customTimers[index];
                                      final remain = _formatDuration(timer.remaining(app.now));
                                      return Card(
                                        color: timer.finished
                                            ? Colors.redAccent.withValues(alpha: 0.25)
                                            : Colors.white10,
                                        child: ListTile(
                                          title: Text(
                                            timer.title,
                                            style: const TextStyle(color: Colors.white),
                                          ),
                                          subtitle: Text(
                                            remain,
                                            style: const TextStyle(color: Colors.white70),
                                          ),
                                          trailing: TextButton(
                                            onPressed: () => app.stopAndRemoveCustomTimer(timer.id),
                                            child: const Text('停止/削除'),
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// タブボタン表示用の小さなウィジェットです。
class _TabButton extends StatelessWidget {
  const _TabButton({required this.label, required this.enabled});

  final String label;
  final bool enabled;

  /// タブボタンの見た目を返す関数です。
  @override
  Widget build(BuildContext context) {
    final color = enabled ? Colors.cyanAccent : Colors.grey;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: enabled ? Colors.white12 : Colors.white10,
          border: Border.all(color: color.withValues(alpha: 0.6)),
        ),
        child: Text(label, style: TextStyle(color: color)),
      ),
    );
  }
}

/// 円形プログレス描画を行う CustomPainter です。
class ProgressCirclePainter extends CustomPainter {
  ProgressCirclePainter({required this.progress, required this.strokeWidth});

  final double progress;
  final double strokeWidth;

  /// キャンバスへ円形ゲージを描画する関数です。
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (math.min(size.width, size.height) - strokeWidth) / 2;

    final basePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..color = Colors.white24;

    final progressPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..color = Colors.cyanAccent;

    canvas.drawCircle(center, radius, basePaint);

    final sweep = 2 * math.pi * progress;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      sweep,
      false,
      progressPaint,
    );
  }

  /// 再描画が必要かを判定する関数です。
  @override
  bool shouldRepaint(covariant ProgressCirclePainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.strokeWidth != strokeWidth;
  }
}

/// 右から左へ文字列を流すためのマルキーウィジェットです。
class MarqueeText extends StatefulWidget {
  const MarqueeText({super.key, required this.text});

  final String text;

  /// State を生成する関数です。
  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

/// マルキー表示の状態管理クラスです。
class _MarqueeTextState extends State<MarqueeText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  /// コントローラーを初期化してループ再生を開始する関数です。
  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(seconds: 8))
      ..repeat();
  }

  /// Widget 更新時にアニメーションの長さを調整する関数です。
  @override
  void didUpdateWidget(covariant MarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text == widget.text) {
      return;
    }
    final sec = (widget.text.length / 3).clamp(6, 20).toInt();
    _controller
      ..duration = Duration(seconds: sec)
      ..repeat();
  }

  /// コントローラーを破棄する関数です。
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// マルキー表示を描画する関数です。
  @override
  Widget build(BuildContext context) {
    const style = TextStyle(fontSize: 14, color: Colors.white70);
    return LayoutBuilder(
      builder: (context, constraints) {
        final tp = TextPainter(
          text: TextSpan(text: widget.text, style: style),
          textDirection: TextDirection.ltr,
          maxLines: 1,
        )..layout();

        final textWidth = tp.width;
        final width = constraints.maxWidth;

        return ClipRect(
          child: AnimatedBuilder(
            animation: _controller,
            builder: (_, __) {
              final dx = width - (width + textWidth) * _controller.value;
              return Transform.translate(
                offset: Offset(dx, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(widget.text, maxLines: 1, overflow: TextOverflow.visible, style: style),
                ),
              );
            },
          ),
        );
      },
    );
  }
}
