import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:onesignal_flutter/onesignal_flutter.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const VogueBarberApp());
}

/// حالة عامة للتطبيق
class AppState {
  static String? playerId; // OneSignal player id
  static int? keepAlive;
}

/// خدمة Firebase عبر REST
class FirebaseService {
  static const String _dbUrl =
      'https://vogue-a2784-default-rtdb.firebaseio.com';

  /// تسجيل PlayerId للآدمن
  static Future<void> saveAdminPlayerId(String playerId) async {
    final uri = Uri.parse('$_dbUrl/Admins.json');
    final body = jsonEncode({
      'PlayerId': playerId,
      'updatedAt': DateTime.now().toIso8601String(),
    });

    final client = HttpClient();
    try {
      final req = await client.patchUrl(uri);
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      req.add(utf8.encode(body));
      final res = await req.close();
      debugPrint('saveAdminPlayerId status: ${res.statusCode}');
    } catch (e) {
      debugPrint('saveAdminPlayerId error: $e');
    } finally {
      client.close();
    }
  }

  /// ربط آخر حجز بـ playerId + حفظ حالته كآخر حالة شافها الزبون (حتى ما يطلع رقم أول مرة)
  static Future<void> attachPlayerIdToLastBooking(String playerId) async {
    final uri = Uri.parse('$_dbUrl/Booking.json');
    final client = HttpClient();
    try {
      final req = await client.getUrl(uri);
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();

      if (text.isEmpty || text == 'null') return;

      final data = jsonDecode(text);
      if (data is! Map) return;
      if (data['error'] != null) {
        debugPrint(
            'attachPlayerIdToLastBooking firebase error: ${data['error']}');
        return;
      }

      String? lastKey;
      Map<String, dynamic>? lastBooking;
      DateTime? lastCreatedAt;

      data.forEach((key, value) {
        if (value is Map) {
          final createdAtStr = value['createdAt']?.toString();
          if (createdAtStr == null) return;
          try {
            final createdAt = DateTime.parse(createdAtStr);
            if (lastCreatedAt == null || createdAt.isAfter(lastCreatedAt!)) {
              lastCreatedAt = createdAt;
              lastKey = key;
              lastBooking = Map<String, dynamic>.from(value);
            }
          } catch (_) {}
        }
      });

      if (lastKey == null || lastBooking == null) return;

      final Map<String, dynamic> safeBooking = lastBooking!;

      // ربط الـ PlayerId بالحجز
      final patchUri = Uri.parse('$_dbUrl/Booking/$lastKey.json');
      final patchBody = jsonEncode({'playerId': playerId});

      final patchReq = await client.patchUrl(patchUri);
      patchReq.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      patchReq.add(utf8.encode(patchBody));
      final patchRes = await patchReq.close();
      debugPrint(
          'attachPlayerIdToLastBooking patch status: ${patchRes.statusCode}');

      // حفظ آخر حالة معروفة لهذا الحجز كـ "مقروءة" للزبون
      final status = safeBooking['status']?.toString() ?? '';
      await updateUserStatus(playerId, lastKey!, status);
    } catch (e) {
      debugPrint('attachPlayerIdToLastBooking error: $e');
    } finally {
      client.close();
    }
  }

  /// عدد حجوزات اليوم بحالة "معلق" فقط (للآدمن)
  static Future<int> fetchPendingBookingsCountToday() async {
    final uri = Uri.parse('$_dbUrl/Booking.json');
    final client = HttpClient();
    final todayStr =
        DateTime.now().toIso8601String().substring(0, 10); // yyyy-MM-dd

    try {
      final req = await client.getUrl(uri);
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      if (text.isEmpty || text == 'null') return 0;

      final data = jsonDecode(text);
      if (data is! Map) return 0;
      if (data['error'] != null) {
        debugPrint(
            'fetchPendingBookingsCountToday firebase error: ${data['error']}');
        return 0;
      }

      int count = 0;
      data.forEach((key, value) {
        if (value is Map) {
          final status = value['status']?.toString();
          final dateStr = value['date']?.toString();
          if (status == null || dateStr == null) return;

          final isPending = status == 'معلق' ||
              status == 'pending' ||
              status == 'بانتظار' ||
              status == 'قيد الانتظار';

          if (isPending && dateStr == todayStr) {
            count++;
          }
        }
      });

      return count;
    } catch (e) {
      debugPrint('fetchPendingBookingsCountToday error: $e');
      return 0;
    } finally {
      client.close();
    }
  }

  /// تحديث حالة آخر حجز معروفة للزبون داخل نفس الحجز
  static Future<void> updateUserStatus(
      String playerId, String bookingKey, String status) async {
    final uri = Uri.parse('$_dbUrl/Booking/$bookingKey.json');
    final body = jsonEncode({
      'seenStatusForPlayer': status,
      'seenUpdatedAt': DateTime.now().toIso8601String(),
    });

    final client = HttpClient();
    try {
      final req = await client.patchUrl(uri);
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      req.add(utf8.encode(body));
      final res = await req.close();
      debugPrint('updateUserStatus (on booking) status: ${res.statusCode}');
    } catch (e) {
      debugPrint('updateUserStatus (on booking) error: $e');
    } finally {
      client.close();
    }
  }

  /// قراءة حجز معيّن حسب الـ key
  static Future<Map<String, dynamic>?> fetchBookingByKey(
      String bookingKey) async {
    final uri = Uri.parse('$_dbUrl/Booking/$bookingKey.json');
    final client = HttpClient();
    try {
      final req = await client.getUrl(uri);
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      if (text.isEmpty || text == 'null') return null;
      final data = jsonDecode(text);
      if (data is Map) {
        if (data['error'] != null) {
          debugPrint('fetchBookingByKey error: ${data['error']}');
          return null;
        }
        return Map<String, dynamic>.from(data);
      }
      return null;
    } catch (e) {
      debugPrint('fetchBookingByKey error: $e');
      return null;
    } finally {
      client.close();
    }
  }

  /// إيجاد آخر حجز مربوط بـ playerId (للزبون)
  static Future<Map<String, dynamic>?> fetchLastBookingForPlayer(
      String playerId) async {
    final uri = Uri.parse('$_dbUrl/Booking.json');
    final client = HttpClient();
    try {
      final req = await client.getUrl(uri);
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      if (text.isEmpty || text == 'null') return null;

      final data = jsonDecode(text);
      if (data is! Map) return null;
      if (data['error'] != null) {
        debugPrint(
            'fetchLastBookingForPlayer firebase error: ${data['error']}');
        return null;
      }

      String? lastKey;
      Map<String, dynamic>? lastBooking;
      DateTime? lastCreatedAt;

      data.forEach((key, value) {
        if (value is Map) {
          if (value['playerId']?.toString() != playerId) return;
          final createdAtStr = value['createdAt']?.toString();
          if (createdAtStr == null) return;
          try {
            final createdAt = DateTime.parse(createdAtStr);
            if (lastCreatedAt == null || createdAt.isAfter(lastCreatedAt!)) {
              lastCreatedAt = createdAt;
              lastKey = key;
              lastBooking = Map<String, dynamic>.from(value);
            }
          } catch (_) {}
        }
      });

      if (lastKey == null || lastBooking == null) return null;

      return {
        'key': lastKey,
        'booking': lastBooking,
      };
    } catch (e) {
      debugPrint('fetchLastBookingForPlayer error: $e');
      return null;
    } finally {
      client.close();
    }
  }

  /// هل هذا الـ PlayerId تابع لآدمن؟
  static Future<bool> isAdminPlayer(String playerId) async {
    final uri = Uri.parse('$_dbUrl/Admins/PlayerId.json');
    final client = HttpClient();
    try {
      final req = await client.getUrl(uri);
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      if (text.isEmpty || text == 'null') return false;
      final data = jsonDecode(text);
      return data is String && data == playerId;
    } catch (e) {
      debugPrint('isAdminPlayer error: $e');
      return false;
    } finally {
      client.close();
    }
  }
}

/// تهيئة OneSignal
Future<void> initOneSignal() async {
  OneSignal.Debug.setLogLevel(OSLogLevel.verbose);
  OneSignal.Debug.setAlertLevel(OSLogLevel.none);

  OneSignal.initialize("0a025461-47e0-495f-81c2-1354aa20fa5c");
  OneSignal.Notifications.requestPermission(true);

  String? playerId;
  for (var i = 0; i < 20; i++) {
    final id = OneSignal.User.pushSubscription.id;
    if (id != null && id.isNotEmpty) {
      playerId = id;
      break;
    }
    await Future.delayed(const Duration(milliseconds: 500));
  }

  AppState.playerId = playerId;
  debugPrint('OneSignal playerId: $playerId');
}

/// فتح إشعار الزبون: آخر حجز فقط
Future<void> openCustomerNotificationFlow(BuildContext context) async {
  final pid = AppState.playerId;
  if (pid == null || pid.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('هێشتا ئایدی تۆمار نەکراوە، تکایە دووبارە هەوڵ بدە'),
      ),
    );
    return;
  }

  String? bookingKey;
  Map<String, dynamic>? booking;

  // نجيب مباشرةً آخر حجز لنفس الـ playerId
  final result = await FirebaseService.fetchLastBookingForPlayer(pid);
  if (result != null) {
    bookingKey = result['key']?.toString();
    booking = (result['booking'] as Map?)?.cast<String, dynamic>();
  }

  if (bookingKey == null || booking == null) {
    await showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SizedBox(
        height: 160,
        child: Center(
          child: Text(
            'هێشتا حجزت نیە یاخود پێشتر تۆمار نەکراوە',
            style: TextStyle(
              color: Colors.grey[800],
              fontSize: 15,
            ),
          ),
        ),
      ),
    );
    return;
  }

  final statusAr = booking['status']?.toString() ?? '';
  final date = booking['date']?.toString() ?? '';
  final time = booking['time']?.toString() ?? '';

  String statusKu;
  switch (statusAr) {
    case 'مقبول':
      statusKu = 'قبوڵکراوە';
      break;
    case 'مرفوض':
      statusKu = 'ڕەتکراوە';
      break;
    case 'معلق':
      statusKu = 'لە چاوەڕوانیدایە';
      break;
    default:
      statusKu = 'دۆخ نەزانراوە';
  }

  await showModalBottomSheet(
    context: context,
    isDismissible: false,
    enableDrag: false,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) {
      return Directionality(
        textDirection: TextDirection.rtl,
        child: Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: 20.0, vertical: 16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Icon(Icons.notifications_active_outlined,
                      color: Colors.black87),
                  const SizedBox(width: 8),
                  const Text(
                    'دۆخی دوایین حجزەکەت',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () async {
                      await FirebaseService.updateUserStatus(
                        pid,
                        bookingKey!,
                        statusAr,
                      );
                      Navigator.pop(context);
                    },
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF3F4F6),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'دۆخ: $statusKu',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'بەروار: $date   –   کات: $time',
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFF4B5563),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      );
    },
  );
}

class VogueBarberApp extends StatelessWidget {
  const VogueBarberApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Vogue Barber',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        scaffoldBackgroundColor: Colors.white,
        useMaterial3: true,
      ),
      initialRoute: '/',
      routes: {
        '/': (context) => const WelcomeScreen(),
        '/customerHome': (context) => const CustomerHomeScreen(),
        '/store': (context) => const StoreScreen(),
        '/booking': (context) => const BookingScreen(),
        '/about': (context) => const AboutScreen(),
        '/payment': (context) => const PaymentScreen(),
        '/adminLogin': (context) => const AdminLoginScreen(),
        '/adminHome': (context) => const AdminHomeScreen(),
        '/adminAppointments': (context) => const AdminAppointmentsScreen(),
        '/adminStats': (context) => const AdminStatsScreen(),
        '/adminStore': (context) => const AdminStoreScreen(),
      },
    );
  }
}

/// =======================
/// Welcome Screen + Global Bell
/// =======================
class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    initOneSignal();

    _timer = Timer.periodic(const Duration(seconds: 10), (_) {
      final randomValue = Random().nextInt(9999) + 1;
      AppState.keepAlive = randomValue;
      debugPrint("keepAlive updated: $randomValue");
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _goToCustomerHome() {
    Navigator.pushNamed(context, '/customerHome');
  }

  void _goToAdminLogin() {
    Navigator.pushNamed(context, '/adminLogin');
  }

  /// زر الجرس في الشاشة الأولى
  Future<void> _onGlobalBellPressed() async {
    final pid = AppState.playerId;
    if (pid == null || pid.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('هێشتا ئایدی تۆمار نەکراوە، تکایە دووبارە هەوڵ بدە.'),
        ),
      );
      return;
    }

    final isAdmin = await FirebaseService.isAdminPlayer(pid);
    if (!mounted) return;

    if (isAdmin) {
      Navigator.pushNamed(context, '/adminAppointments');
    } else {
      await openCustomerNotificationFlow(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      const Spacer(),
                      IconButton(
                        onPressed: _onGlobalBellPressed,
                        icon: const Icon(Icons.notifications_none_rounded),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24.0),
                      child: Image.asset(
                        'assets/images/logo.png',
                        fit: BoxFit.contain,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 32),
                Padding(
                  padding: const EdgeInsets.only(
                    left: 24,
                    right: 24,
                    bottom: 40,
                  ),
                  child: SizedBox(
                    width: double.infinity,
                    height: 54,
                    child: ElevatedButton(
                      onPressed: _goToCustomerHome,
                      style: ElevatedButton.styleFrom(
                        padding: EdgeInsets.zero,
                        elevation: 4,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(28),
                        ),
                        backgroundColor: Colors.transparent,
                        shadowColor: Colors.black26,
                      ),
                      child: Ink(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(28),
                          gradient: const LinearGradient(
                            colors: [Color(0xFF111827), Color(0xFF4B5563)],
                            begin: Alignment.centerRight,
                            end: Alignment.centerLeft,
                          ),
                        ),
                        child: const Center(
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'دەست پێ بکە',
                                style: TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.white,
                                ),
                              ),
                              SizedBox(width: 8),
                              Icon(
                                Icons.arrow_forward_rounded,
                                color: Colors.white,
                                size: 22,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),

            /// زر مخفي للآدمن – فوق اللوغو
            Positioned(
              left: 0,
              right: 0,
              top: 80,
              height: 160,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: _goToAdminLogin,
                child: Container(color: Colors.transparent),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// =======================
/// Customer Home + Badge
/// =======================
class CustomerHomeScreen extends StatefulWidget {
  const CustomerHomeScreen({super.key});

  @override
  State<CustomerHomeScreen> createState() => _CustomerHomeScreenState();
}

class _CustomerHomeScreenState extends State<CustomerHomeScreen> {
  int _badgeCount = 0;
  bool _loading = false;

  Future<void> _loadBadge() async {
    setState(() => _loading = true);

    int count = 0;
    final pid = AppState.playerId;
    if (pid != null && pid.isNotEmpty) {
      final last = await FirebaseService.fetchLastBookingForPlayer(pid);
      if (last != null) {
        final booking = (last['booking'] as Map).cast<String, dynamic>();
        final currentStatus = booking['status']?.toString() ?? '';
        final lastSeenStatus =
            booking['seenStatusForPlayer']?.toString() ?? '';

        if (currentStatus.isNotEmpty && currentStatus != lastSeenStatus) {
          count = 1; // فقط آخر حجز إذا تغيرت حالته
        }
      }
    }

    if (!mounted) return;
    setState(() {
      _badgeCount = count;
      _loading = false;
    });
  }

  @override
  void initState() {
    super.initState();
    _loadBadge();
  }

  Future<void> _onBellPressed() async {
    await openCustomerNotificationFlow(context);
    await _loadBadge();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Container(
          color: Colors.white,
          child: Column(
            children: [
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16.0, vertical: 10),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.chevron_left,
                          color: Colors.black87),
                      onPressed: () {
                        Navigator.pop(context);
                      },
                    ),
                    const Spacer(),
                    Stack(
                      children: [
                        IconButton(
                          onPressed: _onBellPressed,
                          icon: const Icon(Icons.notifications_none_rounded),
                        ),
                        if (_badgeCount > 0)
                          Positioned(
                            right: 10,
                            top: 10,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 5, vertical: 1),
                              decoration: BoxDecoration(
                                color: Colors.red,
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: const Text(
                                '1',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                        if (_loading)
                          const Positioned(
                            right: 10,
                            bottom: 6,
                            child: SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24.0),
                child: Column(
                  children: [
                    Image.asset(
                      'assets/images/logo.png',
                      height: 120,
                      fit: BoxFit.contain,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'هەموو کارەکانی کات دانان و نۆرەگرتن لەسەر یەک ئەپ، بە ئاسانی بە کەمترین کات',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Color(0xFF4B5563),
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20.0, vertical: 8),
                  child: Column(
                    children: [
                      _HomeActionCard(
                        title: 'بازاڕ',
                        subtitle: 'بەرهەمەکانی گرنگی پێدان و قژ',
                        icon: Icons.storefront_outlined,
                        color: const Color(0xFF0EA5E9),
                        onTap: () {
                          Navigator.pushNamed(context, '/store');
                        },
                      ),
                      const SizedBox(height: 12),
                      _HomeActionCard(
                        title: 'کات دانان',
                        subtitle:
                            'کاتەکەت دیاری بکە بە چرکەیەک، بێ پەیوەندی کردن',
                        icon: Icons.calendar_month_outlined,
                        color: const Color(0xFF22C55E),
                        onTap: () {
                          Navigator.pushNamed(context, '/booking');
                        },
                      ),
                      const SizedBox(height: 12),
                      _HomeActionCard(
                        title: 'ئێمە کێین؟',
                        subtitle:
                            'شوێن، خزمەتگوزاریەکان و کاتەکانی کارکردن',
                        icon: Icons.info_outline,
                        color: const Color(0xFFF97316),
                        onTap: () {
                          Navigator.pushNamed(context, '/about');
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HomeActionCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _HomeActionCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            color: Colors.white,
            boxShadow: const [
              BoxShadow(
                color: Color(0x11000000),
                blurRadius: 10,
                offset: Offset(0, 4),
              ),
            ],
            border: Border.all(
              color: const Color(0xFFE5E7EB),
              width: 1,
            ),
          ),
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: color.withOpacity(0.15),
                child: Icon(icon, color: color, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF111827),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF6B7280),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// =======================
/// WebView Screens (Store / Payment / Booking / About)
/// =======================

class StoreScreen extends StatefulWidget {
  const StoreScreen({super.key});

  @override
  State<StoreScreen> createState() => _StoreScreenState();
}

class _StoreScreenState extends State<StoreScreen> {
  late final WebViewController _controller;

  void _handleStoreMessage(String message) {
    debugPrint('Store message: $message');
    try {
      final data = jsonDecode(message);
      if (data is Map && data['type'] == 'NAVIGATE_TO_PAYMENT') {
        Navigator.pushNamed(context, '/payment');
        return;
      }
    } catch (_) {
      if (message.trim() == 'NAVIGATE_TO_PAYMENT') {
        Navigator.pushNamed(context, '/payment');
      }
    }
  }

  void _onBack() {
    Navigator.pushReplacementNamed(context, '/customerHome');
  }

  @override
  void initState() {
    super.initState();

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..addJavaScriptChannel(
        'VOGUE',
        onMessageReceived: (JavaScriptMessage message) {
          _handleStoreMessage(message.message);
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) => debugPrint('Store started: $url'),
          onPageFinished: (url) => debugPrint('Store finished: $url'),
        ),
      )
      ..loadRequest(
        Uri.parse('https://vogue-a2784.web.app/Vouge.C.S'),
      );

    _controller.clearCache();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              top: 48,
              child: WebViewWidget(controller: _controller),
            ),
            Positioned(
              top: 4,
              left: 4,
              child: IconButton(
                icon: const Icon(Icons.chevron_left, color: Colors.black87),
                onPressed: _onBack,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class PaymentScreen extends StatefulWidget {
  const PaymentScreen({super.key});

  @override
  State<PaymentScreen> createState() => _PaymentScreenState();
}

class _PaymentScreenState extends State<PaymentScreen> {
  late final WebViewController _controller;

  void _goHome() {
    Navigator.pushNamedAndRemoveUntil(
      context,
      '/customerHome',
      (route) => false,
    );
  }

  void _handlePaymentMessage(String message) {
    debugPrint('Payment message: $message');
    try {
      final data = jsonDecode(message);
      if (data is Map && data['type'] == 'PAY_CONFIRMED') {
        _goHome();
        return;
      }
    } catch (_) {
      if (message.trim() == 'PAY_CONFIRMED') {
        _goHome();
      }
    }
  }

  @override
  void initState() {
    super.initState();

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..addJavaScriptChannel(
        'VOGUE',
        onMessageReceived: (JavaScriptMessage message) {
          _handlePaymentMessage(message.message);
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) => debugPrint('PAY started: $url'),
          onPageFinished: (url) => debugPrint('PAY finished: $url'),
        ),
      )
      ..loadRequest(
        Uri.parse('https://vogue-a2784.web.app/Vouge.PAY'),
      );

    _controller.clearCache();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              top: 48,
              child: WebViewWidget(controller: _controller),
            ),
            Positioned(
              top: 4,
              left: 4,
              child: IconButton(
                icon: const Icon(Icons.chevron_left, color: Colors.black87),
                onPressed: _goHome,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class BookingScreen extends StatefulWidget {
  const BookingScreen({super.key});

  @override
  State<BookingScreen> createState() => _BookingScreenState();
}

class _BookingScreenState extends State<BookingScreen> {
  late final WebViewController _controller;

  void _goHome() {
    Navigator.pushNamedAndRemoveUntil(
      context,
      '/customerHome',
      (route) => false,
    );
  }

  Future<void> _handleBookingMessage(String message) async {
    debugPrint('Booking message: $message');

    bool success = false;
    try {
      final data = jsonDecode(message);
      if (data is Map && data['type'] == 'BOOKING_SUCCESS') {
        success = true;
      }
    } catch (_) {
      if (message.trim() == 'BOOKING_SUCCESS') {
        success = true;
      }
    }

    if (success) {
      final pid = AppState.playerId;
      if (pid != null && pid.isNotEmpty) {
        await FirebaseService.attachPlayerIdToLastBooking(pid);
      }
      _goHome();
    }
  }

  @override
  void initState() {
    super.initState();

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..addJavaScriptChannel(
        'VOGUE',
        onMessageReceived: (JavaScriptMessage message) {
          _handleBookingMessage(message.message);
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) => debugPrint('Booking started: $url'),
          onPageFinished: (url) => debugPrint('Booking finished: $url'),
        ),
      )
      ..loadRequest(
        Uri.parse('https://vogue-a2784.web.app/Vouge.Booking'),
      );

    _controller.clearCache();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              top: 48,
              child: WebViewWidget(controller: _controller),
            ),
            Positioned(
              top: 4,
              left: 4,
              child: IconButton(
                icon: const Icon(Icons.chevron_left, color: Colors.black87),
                onPressed: _goHome,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// =======================
/// About Screen (ئێمە کێین؟) مع فتح الروابط الخارجية برّه
/// =======================
class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key});

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  late final WebViewController _controller;

  /// هل الرابط من نفس موقع الصالون (صفحة التعريف)؟
  bool _isSameHost(String url) {
    try {
      final uri = Uri.parse(url);
      // عدلها إذا غيرت الدومين بالمستقبل
      return uri.host == 'vogue-a2784.web.app';
    } catch (_) {
      return false;
    }
  }

  /// فتح أي رابط خارجي (واتساب، اتصال، ماب، إنستا، ..إلخ)
  Future<void> _launchExternal(String url) async {
    debugPrint('Launching external: $url');
    try {
      final uri = Uri.parse(url);

      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );

      if (!launched) {
        await launchUrl(
          uri,
          mode: LaunchMode.platformDefault,
        );
      }
    } catch (e) {
      debugPrint('Error launching external url: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('نەتوانرا بەستەر بکرتەوە'),
        ),
      );
    }
  }

  void _goBack() {
    Navigator.pushReplacementNamed(context, '/customerHome');
  }

  @override
  void initState() {
    super.initState();

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (NavigationRequest request) {
            debugPrint('About nav request: ${request.url}');

            // إذا مو من نفس الموقع → نفتح برّه
            if (!_isSameHost(request.url)) {
              _launchExternal(request.url);
              return NavigationDecision.prevent;
            }

            // غير هذا خليه طبيعي جوه الويب فيو
            return NavigationDecision.navigate;
          },
          onPageStarted: (url) =>
              debugPrint('About page started: $url'),
          onPageFinished: (url) =>
              debugPrint('About page finished: $url'),
        ),
      )
      ..loadRequest(
        // نفس صفحة الـ HTML الي انت مسويها (بكوردي سوراني)
        Uri.parse('https://vogue-a2784.web.app/vougeabout'),
      );

    _controller.clearCache();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              top: 48,
              child: WebViewWidget(controller: _controller),
            ),
            Positioned(
              top: 4,
              left: 4,
              child: IconButton(
                icon: const Icon(Icons.chevron_left, color: Colors.black87),
                onPressed: _goBack,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// =======================
/// Admin Login
/// =======================
class AdminLoginScreen extends StatefulWidget {
  const AdminLoginScreen({super.key});

  @override
  State<AdminLoginScreen> createState() => _AdminLoginScreenState();
}

class _AdminLoginScreenState extends State<AdminLoginScreen> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _passController = TextEditingController();
  bool _isLoading = false;
  String? _errorMessage;

  bool _validateCredentials(String name, String password) {
    final trimmedName = name.trim();
    final trimmedPass = password.trim();
    if (trimmedName.isEmpty || trimmedPass.isEmpty) return false;
    const mainCode = 'b';
    const backupCode = 'bb';
    return trimmedPass == mainCode || trimmedPass == backupCode;
  }

  Future<void> _onLoginPressed() async {
    final name = _nameController.text;
    final pass = _passController.text;

    setState(() => _errorMessage = null);

    if (!_validateCredentials(name, pass)) {
      setState(() => _errorMessage = 'ناو یان وشەی نهێنی هەڵەیە');
      return;
    }

    setState(() => _isLoading = true);

    final pid = AppState.playerId;
    if (pid != null && pid.isNotEmpty) {
      await FirebaseService.saveAdminPlayerId(pid);
    }

    setState(() => _isLoading = false);

    if (!mounted) return;
    Navigator.pushReplacementNamed(context, '/adminHome');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: Directionality(
              textDirection: TextDirection.rtl,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Image.asset(
                    'assets/images/logo.png',
                    height: 110,
                    fit: BoxFit.contain,
                  ),
                  const SizedBox(height: 24),
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x33000000),
                          blurRadius: 18,
                          offset: Offset(0, 8),
                        ),
                      ],
                    ),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 22),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: const [
                            Icon(Icons.admin_panel_settings_outlined,
                                color: Color(0xFF0F172A)),
                            SizedBox(width: 8),
                            Text(
                              'چوونەژوورەوەی بەڕێوبەر',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF0F172A),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 18),
                        TextField(
                          controller: _nameController,
                          textDirection: TextDirection.rtl,
                          decoration: InputDecoration(
                            labelText: 'ناوی بەکارهێنەر',
                            prefixIcon: const Icon(Icons.person_outline),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                        ),
                        const SizedBox(height: 14),
                        TextField(
                          controller: _passController,
                          obscureText: true,
                          textDirection: TextDirection.rtl,
                          decoration: InputDecoration(
                            labelText: 'وشەی نهێنی',
                            prefixIcon: const Icon(Icons.lock_outline),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        if (_errorMessage != null)
                          Text(
                            _errorMessage!,
                            style: const TextStyle(
                              color: Colors.red,
                              fontSize: 12,
                            ),
                          ),
                        const SizedBox(height: 18),
                        SizedBox(
                          width: double.infinity,
                          height: 48,
                          child: ElevatedButton(
                            onPressed: _isLoading ? null : _onLoginPressed,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF0F172A),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(18),
                              ),
                            ),
                            child: _isLoading
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      valueColor:
                                          AlwaysStoppedAnimation(Colors.white),
                                    ),
                                  )
                                : Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    mainAxisSize: MainAxisSize.min,
                                    children: const [
                                      Icon(Icons.login, color: Colors.white),
                                      SizedBox(width: 8),
                                      Text(
                                        'چوونەژوورەوە',
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 16,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: () {
                      Navigator.pop(context);
                    },
                    child: const Text(
                      'گەڕانەوە بۆ سەرەتا',
                      style: TextStyle(color: Color(0xFF4B5563)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// =======================
/// Admin Home + Badge (تصميم جديد)
/// =======================
class AdminHomeScreen extends StatefulWidget {
  const AdminHomeScreen({super.key});

  @override
  State<AdminHomeScreen> createState() => _AdminHomeScreenState();
}

class _AdminHomeScreenState extends State<AdminHomeScreen> {
  int _pendingCount = 0;
  Timer? _timer;
  bool _loading = false;

  Future<void> _loadPending() async {
    setState(() => _loading = true);
    final count = await FirebaseService.fetchPendingBookingsCountToday();
    if (!mounted) return;
    setState(() {
      _pendingCount = count;
      _loading = false;
    });
  }

  @override
  void initState() {
    super.initState();
    _loadPending();
    _timer = Timer.periodic(const Duration(seconds: 20), (_) => _loadPending());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _openAppointments() {
    Navigator.pushNamed(context, '/adminAppointments');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Container(
          color: Colors.white,
          child: Column(
            children: [
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16.0, vertical: 10),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.chevron_left,
                          color: Colors.black87),
                      onPressed: () {
                        Navigator.pushNamedAndRemoveUntil(
                            context, '/', (route) => false);
                      },
                    ),
                    const SizedBox(width: 4),
                    const Text(
                      'پەنەڵی بەڕێوبەر',
                      style: TextStyle(
                        color: Colors.black87,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    Stack(
                      children: [
                        IconButton(
                          onPressed: _openAppointments,
                          icon: const Icon(Icons.notifications_none_rounded),
                        ),
                        if (_pendingCount > 0)
                          Positioned(
                            right: 10,
                            top: 10,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 5, vertical: 1),
                              decoration: BoxDecoration(
                                color: Colors.red,
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                '$_pendingCount',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                        if (_loading)
                          const Positioned(
                            right: 10,
                            bottom: 6,
                            child: SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24.0),
                child: Column(
                  children: [
                    Image.asset(
                      'assets/images/logo.png',
                      height: 110,
                      fit: BoxFit.contain,
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20.0, vertical: 8),
                  child: Directionality(
                    textDirection: TextDirection.rtl,
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: _AdminActionCard(
                                title: 'مۆعید',
                                icon: Icons.event_note_outlined,
                                color: const Color(0xFF0EA5E9),
                                onTap: _openAppointments,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _AdminActionCard(
                                title: 'ئامار',
                                icon: Icons.bar_chart_rounded,
                                color: const Color(0xFF6366F1),
                                onTap: () {
                                  Navigator.pushNamed(
                                      context, '/adminStats');
                                },
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        _AdminActionCard(
                          title: 'بازاڕی بەرهەمەکان',
                          icon: Icons.store_mall_directory_outlined,
                          color: const Color(0xFFF97316),
                          onTap: () {
                            Navigator.pushNamed(context, '/adminStore');
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AdminActionCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _AdminActionCard({
    required this.title,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: LinearGradient(
            colors: [
              color.withOpacity(0.12),
              color.withOpacity(0.03),
            ],
            begin: Alignment.topRight,
            end: Alignment.bottomLeft,
          ),
          border: Border.all(
            color: color.withOpacity(0.35),
            width: 1,
          ),
          boxShadow: const [
            BoxShadow(
              color: Color(0x11000000),
              blurRadius: 10,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 22,
              backgroundColor: color.withOpacity(0.18),
              child: Icon(icon, color: color, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF111827),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// =======================
/// Admin Webview Screens
/// =======================

class AdminAppointmentsScreen extends StatefulWidget {
  const AdminAppointmentsScreen({super.key});

  @override
  State<AdminAppointmentsScreen> createState() =>
      _AdminAppointmentsScreenState();
}

class _AdminAppointmentsScreenState extends State<AdminAppointmentsScreen> {
  late final WebViewController _controller;

  void _onBack() {
    Navigator.pop(context);
  }

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) =>
              debugPrint('Admin appointments: $url'),
          onPageFinished: (url) =>
              debugPrint('Admin appointments done'),
        ),
      )
      ..loadRequest(
        Uri.parse('https://vogue-a2784.web.app/Vouge.C.N'),
      );
    _controller.clearCache();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              top: 48,
              child: WebViewWidget(controller: _controller),
            ),
            Positioned(
              top: 4,
              left: 4,
              child: IconButton(
                icon: const Icon(Icons.chevron_left, color: Colors.black87),
                onPressed: _onBack,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// =======================
/// Admin Stats (بدون InAppWebView) مع دعم تصدير الملفات عبر النظام
/// =======================
class AdminStatsScreen extends StatefulWidget {
  const AdminStatsScreen({super.key});

  @override
  State<AdminStatsScreen> createState() => _AdminStatsScreenState();
}

class _AdminStatsScreenState extends State<AdminStatsScreen> {
  final String _statsUrl = 'https://vogue-a2784.web.app/Vouge.Stat';
  late final WebViewController _controller;

  void _onBack() {
    Navigator.pop(context);
  }

  bool _isDownloadUrl(String url) {
    final lower = url.toLowerCase();
    return lower.endsWith('.xlsx') ||
        lower.endsWith('.xls') ||
        lower.endsWith('.csv') ||
        lower.contains('export');
  }

  Future<void> _openExternal(String url) async {
    try {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      debugPrint('AdminStats download error: $e');
    }
  }

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (NavigationRequest request) async {
            debugPrint('Admin stats nav: ${request.url}');
            if (_isDownloadUrl(request.url)) {
              await _openExternal(request.url);
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
          onPageStarted: (url) =>
              debugPrint('Admin stats started: $url'),
          onPageFinished: (url) =>
              debugPrint('Admin stats finished: $url'),
        ),
      )
      ..loadRequest(Uri.parse(_statsUrl));
    _controller.clearCache();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              top: 48,
              child: WebViewWidget(controller: _controller),
            ),
            Positioned(
              top: 4,
              left: 4,
              child: IconButton(
                icon: const Icon(Icons.chevron_left, color: Colors.black87),
                onPressed: _onBack,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// =======================
/// Admin Store (بدون InAppWebView) مع دعم تحميل/رفع حسب قدرات WebView
/// =======================
class AdminStoreScreen extends StatefulWidget {
  const AdminStoreScreen({super.key});

  @override
  State<AdminStoreScreen> createState() => _AdminStoreScreenState();
}

class _AdminStoreScreenState extends State<AdminStoreScreen> {
  final String _storeUrl = 'https://vogue-a2784.web.app/Vouge.A.S';
  late final WebViewController _controller;

  void _onBack() {
    Navigator.pop(context);
  }

  bool _isDownloadUrl(String url) {
    final lower = url.toLowerCase();
    return lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.pdf') ||
        lower.endsWith('.xlsx') ||
        lower.endsWith('.xls') ||
        lower.endsWith('.csv') ||
        lower.contains('download');
  }

  Future<void> _openExternal(String url) async {
    try {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      debugPrint('AdminStore external error: $e');
    }
  }

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (NavigationRequest request) async {
            debugPrint('Admin store nav: ${request.url}');
            if (_isDownloadUrl(request.url)) {
              await _openExternal(request.url);
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
          onPageStarted: (url) =>
              debugPrint('Admin store started: $url'),
          onPageFinished: (url) =>
              debugPrint('Admin store finished: $url'),
        ),
      )
      ..loadRequest(Uri.parse(_storeUrl));
    _controller.clearCache();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              top: 48,
              child: WebViewWidget(controller: _controller),
            ),
            Positioned(
              top: 4,
              left: 4,
              child: IconButton(
                icon: const Icon(Icons.chevron_left, color: Colors.black87),
                onPressed: _onBack,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
