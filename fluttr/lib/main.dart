import 'package:flutter/material.dart';
import 'package:fluttr/src/rust/api/simple.dart';
import 'package:fluttr/src/rust/api/nostr.dart';
import 'package:fluttr/src/rust/frb_generated.dart';

Future<void> main() async {
  await RustLib.init();
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('flutter_rust_bridge quickstart')),
        body: Center(
          child: Text(
            'Action: Call Rust `greet("Tom")`\nResult: `${greet(name: "Tom")}`',
          ),
        ),
      ),
    );
  }

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  String _lastEventJson = 'Loading…';

  @override
  void initState() {
    super.initState();
    loadDms();
    // loadLastEvent();
  }

  Future<void> loadDms() async {
    const nsec = "nsec15rhnmk6lrww6ekmm8jtsntuhxnej0mvsdxkzw5rntqdz49reksrq6nnmk6";
    try {
      final dms = await fetchDms(nsec: nsec, utcFrom: '', utcTo: '');
      setState(() => _lastEventJson = dms);
    } catch (e) {
      setState(() => _lastEventJson = 'Error: $e');
    }
  }

  // Future<void> loadLastEvent() async {
  //   const npub =
  //       'npub1080l37pfvdpyuzasyuy2ytjykjvq3ylr5jlqlg7tvzjrh9r8vn3sf5yaph';
  //   try {
  //     final json = await fetchLastEvent(npub: npub);
  //     setState(() => _lastEventJson = json);
  //   } catch (e) {
  //     setState(() => _lastEventJson = 'Error: $e');
  //   }
  // }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Last Nostr Event')),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(_lastEventJson),
        ),
      ),
    );
  }
}
